using Misc: MM, toprecision, DFT
using Python: pybuiltins, pyisinstance
using Instruments: AbstractCash
import Instruments: value
Instruments.@importcash!
import Base: ==, +, -, ÷, /, *
import Misc: gtxzero, ltxzero, approxzero

const currenciesCache1Hour = TTL{ExchangeID,Py}(Hour(1))

function to_float(py::Py, T::Type{<:AbstractFloat}=Float64)
    something(pyconvert(Option{T}, py), 0.0)
end

function _lpf(exc, cur)
    @assert pyisinstance(cur, pybuiltins.dict) "Wrong currency: $sym_str not found on $(exc.name)"
    limits = let l = cur.get("limits", nothing)
        if isnothing(l)
            (min=0.0, max=Inf)
        else
            MM{DFT}((to_float(l["amount"]["min"]), to_float(l["amount"]["max"])))
        end
    end
    precision = to_float(cur.get("precision"))
    fees = to_float(cur.get("fee", nothing))
    (; limits, precision, fees)
end

function _cur(exc, sym)
    sym_str = uppercase(string(sym))
    curs = @lget! currenciesCache1Hour exc.id pyfetch(exc.fetchCurrencies)
    curs.get(sym_str, nothing)
end

@doc "A `CurrencyCash` contextualizes a `Cash` instance w.r.t. an exchange.
Operations are rounded to the currency precision."
struct CurrencyCash{C<:Cash,E<:ExchangeID} <: AbstractCash
    cash::C
    limits::MM{DFT}
    precision::T where {T<:Real}
    fees::DFT
    function CurrencyCash(id::Type{<:ExchangeID}, cash_type::Type{<:Cash}, v)
        exc = getexchange!(id.parameters[1])
        c = cash_type(v)
        lpf = _lpf(exc, _cur(exc, nameof(c)))
        Instruments.cash!(c, toprecision(c.value, lpf.precision))
        new{cash_type,id}(c, lpf...)
    end
    function CurrencyCash(exc::Exchange, sym, v=0.0)
        cur = _cur(exc, sym)
        c = Cash(sym, v)
        lpf = _lpf(exc, cur)
        Instruments.cash!(c, toprecision(c.value, lpf.precision))
        new{typeof(c),typeof(exc.id)}(c, lpf...)
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
Base.setproperty!(::CurrencyCash, ::Symbol, v) = error("CurrencyCash is private.")
Base.zero(c::Union{CurrencyCash,Type{CurrencyCash}}) = zero(_cash(c))
Base.iszero(c::CurrencyCash) = isapprox(value(c), zero(c); atol=_prec(c))

function Base.show(io::IO, c::CurrencyCash{<:Cash,E}) where {E<:ExchangeID}
    write(io, "$(c.cash) (on $(E.parameters[1]))")
end
Base.hash(c::CurrencyCash, args...) = hash(_cash(c)args...)
Base.nameof(c::CurrencyCash) = nameof(_cash(c))

Base.promote(c::CurrencyCash, n) = promote(_cash(c)n)
Base.promote(n, c::CurrencyCash) = promote(n, _cash(c))

Base.convert(::Type{T}, c::CurrencyCash) where {T<:Real} = convert(T, _cash(c))
Base.isless(a::CurrencyCash, b::CurrencyCash) = isless(_cash(a), _cash(b))
Base.isless(a::CurrencyCash, b::Number) = isless(promote(a, b)...)
Base.isless(b::Number, a::CurrencyCash) = isless(promote(b, a)...)

Base.abs(c::CurrencyCash) = abs(_cash(c))
Base.real(c::CurrencyCash) = real(_cash(c))

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
        cv[1] = _toprec(c, op(cv[1], v))
    end

add!(c::CurrencyCash, v) = _applyop!(+, c, v)
sub!(c::CurrencyCash, v) = _applyop!(-, c, v)
mul!(c::CurrencyCash, v) = _applyop!(*, c, v)
rdiv!(c::CurrencyCash, v) = _applyop!(/, c, v)
div!(c::CurrencyCash, v) = div!(_cash(c), v)
mod!(c::CurrencyCash, v) = mod!(_cash(c), v)
cash!(c::CurrencyCash, v) = cash!(_cash(c), _toprec(c, v))
addzero!(c::CurrencyCash, v) = addzero!(_cash(c), v; atol=_prec(c))
subzero!(c::CurrencyCash, v) = subzero!(_cash(c), v; atol=_prec(c))

gtxzero(c::CurrencyCash) = gtxzero(value(c); atol=getfield(c, :precision))
ltxzero(c::CurrencyCash) = ltxzero(value(c); atol=getfield(c, :precision))
approxzero(c::CurrencyCash) = approxzero(value(c); atol=getfield(c, :precision))
