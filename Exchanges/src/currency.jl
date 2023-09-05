using Misc: MM, toprecision, DFT
using Python: pybuiltins, pyisinstance
using Python.PythonCall: pyfloat, pyint
using Instruments: AbstractCash, atleast!
import Instruments: value, addzero!
Instruments.@importcash!
import Base: ==, +, -, ÷, /, *
import Misc: gtxzero, ltxzero, approxzero

const currenciesCache1Hour = safettl(ExchangeID, Py, Hour(1))
const currency_lock = ReentrantLock()

function to_float(py::Py, T::Type{<:AbstractFloat}=DFT)
    something(pyconvert(Option{T}, py), zero(T))
end

function to_num(py::Py)
    v = if pyisinstance(py, pybuiltins.int)
        pyconvert(Option{Int}, py)
    elseif pyisinstance(py, pybuiltins.float)
        pyconvert(Option{DFT}, py)
    elseif pyisinstance(py, (pybuiltins.tuple, pybuiltins.list)) && length(py) > 0
        to_num(py[0])
    elseif pyisinstance(py, pybuiltins.str)
        isempty(py) ? 0 : pyconvert(DFT, pyfloat(py))
    else
        pyconvert(Option{DFT}, pyfloat(py))
    end
    @something v 0
end

function _lpf(exc, cur)
    local limits, precision, fees
    if isnothing(cur) || pyisnone(cur)
        limits = (; min=1e-8, max=1e8)
        precision = 8
        fees = zero(DFT)
    else
        limits = let l = get(cur, "limits", nothing)
            if isnothing(l)
                (min=1e-8, max=1e8)
            elseif haskey(l, "amount")
                MM{DFT}((to_float(l["amount"]["min"]), to_float(l["amount"]["max"])))
            else
                (min=1e-8, max=1e8)
            end
        end
        precision = to_num(get(cur, "precision", nothing))
        fees = to_float(get(cur, "fee", nothing))
    end
    (; limits, precision, fees)
end

function _cur(exc, sym)
    sym_str = uppercase(string(sym))
    curs = @lget! currenciesCache1Hour exc.id let v = pyfetch(exc.fetchCurrencies)
        v isa PyException ? exc.currencies : v
    end
    isempty(curs) ? nothing : get(curs, sym_str, nothing)
end

@doc "A `CurrencyCash` contextualizes a `Cash` instance w.r.t. an exchange.
Operations are rounded to the currency precision."
struct CurrencyCash{C<:Cash,E<:ExchangeID} <: AbstractCash
    cash::C
    limits::MM{DFT}
    precision::T where {T<:Real}
    fees::DFT
    function CurrencyCash(id::Type{<:ExchangeID}, cash_type::Type{<:Cash}, v)
        lock(currency_lock) do
            exc = getexchange!(nameof(id))
            c = cash_type(v)
            lpf = _lpf(exc, _cur(exc, nameof(c)))
            Instruments.cash!(c, toprecision(c.value, lpf.precision))
            new{cash_type,id}(c, lpf...)
        end
    end
    function CurrencyCash(exc::Exchange, sym, v=0.0)
        lock(currency_lock) do
            cur = _cur(exc, sym)
            pyisinstance(cur, pybuiltins.dict) ||
                @debug "$sym not found on $(exc.name) (using defaults)"
            c = Cash(sym, v)
            lpf = _lpf(exc, cur)
            Instruments.cash!(c, toprecision(c.value, lpf.precision))
            new{typeof(c),typeof(exc.id)}(c, lpf...)
        end
    end
end

function CurrencyCash{C,E}(v) where {C<:Cash,E<:ExchangeID}
    CurrencyCash(E, C, v)
end

function CurrencyCash(::CurrencyCash{C,E}, v) where {C<:Cash,E<:ExchangeID}
    CurrencyCash(E, C, v)
end

value(cc::CurrencyCash) = value(cc.cash)
Base.getproperty(c::CurrencyCash, s::Symbol) =
    if s == :value
        getfield(_cash(c), :value)[]
    elseif s == :id
        nameof(_cash(c))
    else
        getfield(c, s)
    end
function Base.isapprox(cc::C, v::N) where {C<:CurrencyCash,N<:Number}
    isapprox(value(cc), v; atol=_prec(cc))
end
Base.isapprox(v::N, cc::C) where {C<:CurrencyCash,N<:Number} = isapprox(cc, v)
Base.setproperty!(::CurrencyCash, ::Symbol, v) = error("CurrencyCash is private.")
Base.zero(c::Union{<:CurrencyCash,Type{<:CurrencyCash}}) = zero(c.cash)
function Base.iszero(c::CurrencyCash{Cash{S,T}}) where {S,T}
    isapprox(value(c), zero(T); atol=_prec(c))
end

function Base.show(io::IO, c::CurrencyCash{<:Cash,E}) where {E<:ExchangeID}
    write(io, "$(c.cash) (on $(E.parameters[1]))")
end
Base.hash(c::CurrencyCash, args...) = hash(_cash(c), args...)
Base.nameof(c::CurrencyCash) = nameof(_cash(c))

Base.promote(c::CurrencyCash, n) = promote(_cash(c), n)
Base.promote(n, c::CurrencyCash) = promote(n, _cash(c))

Base.convert(::Type{T}, c::CurrencyCash) where {T<:Real} = convert(T, _cash(c))
Base.isless(a::CurrencyCash, b::CurrencyCash) = isless(_cash(a), _cash(b))
Base.isless(a::CurrencyCash, b::Number) = isless(promote(a, b)...)
Base.isless(b::Number, a::CurrencyCash) = isless(promote(b, a)...)

Base.abs(c::CurrencyCash) = _toprec(c, abs(_cash(c)))
Base.real(c::CurrencyCash) = _toprec(c, real(_cash(c)))

_cash(cc::CurrencyCash) = getfield(cc, :cash)
_prec(cc::CurrencyCash) = getfield(cc, :precision)
_toprec(cc::AbstractCash, v) = toprecision(v, _prec(cc))
_toprec(cc::AbstractCash, c::Cash) = toprecision(value(c), _prec(cc))

-(a::CurrencyCash, b::Real) = _toprec(a, a.cash - b)
+(a::CurrencyCash, b::Real) = _toprec(a, a.cash + b)
*(a::CurrencyCash, b::Real) = _toprec(a, a.cash * b)
/(a::CurrencyCash, b::Real) = _toprec(a, a.cash / b)
÷(a::CurrencyCash, b::Real) = a.cash ÷ b

==(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = _cash(b) == _cash(a)
÷(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = _cash(a) ÷ _cash(b)
*(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = _toprec(a, _cash(a) * _cash(b))
/(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = _toprec(a, _cash(a) / _cash(b))
+(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = _toprec(a, _cash(a) + _cash(b))
-(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = _toprec(a, _cash(a) - _cash(b))

_applyop!(op, c, v) =
    let cv = getfield(_cash(c), :value)
        cv[] = _toprec(c, op(cv[], v))
    end

add!(c::CurrencyCash, v) = _applyop!(+, c, v)
sub!(c::CurrencyCash, v) = _applyop!(-, c, v)
mul!(c::CurrencyCash, v) = _applyop!(*, c, v)
rdiv!(c::CurrencyCash, v) = _applyop!(/, c, v)
div!(c::CurrencyCash, v) = div!(_cash(c), v)
mod!(c::CurrencyCash, v) = mod!(_cash(c), v)
cash!(c::CurrencyCash, v) = cash!(_cash(c), _toprec(c, v))
addzero!(c::CurrencyCash, v, args...; atol=_prec(c), kwargs...) = begin
    add!(c, v)
    atleast!(c; atol)
    c
end

gtxzero(c::CurrencyCash) = gtxzero(value(c); atol=getfield(c, :precision))
ltxzero(c::CurrencyCash) = ltxzero(value(c); atol=getfield(c, :precision))
approxzero(c::CurrencyCash) = approxzero(value(c); atol=getfield(c, :precision))
