using Misc: MM, toprecision, DFT
using Python: pybuiltins, pyisinstance

function to_float(py::Py, T::Type{<:AbstractFloat}=Float64)
    something(pyconvert(Option{T}, py), 0.0)
end

const currenciesCache1Hour = TTL{Nothing,Py}(Hour(1))
@doc "A `CurrencyCash` contextualizes a `Cash` instance w.r.t. an exchange."
struct CurrencyCash{C<:Cash,E<:ExchangeID}
    cash::C
    limits::MM{DFT}
    precision::T where {T<:Real}
    fees::DFT
    function CurrencyCash(exc::Exchange, sym)
        sym_str = uppercase(string(sym))
        c = Cash(sym, 0.0)
        curs = @lget! currenciesCache1Hour nothing pyfetch(exc.fetchCurrencies)
        cur = curs.get(sym_str, nothing)
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
        new{typeof(c),typeof(exc.id)}(c, limits, precision, fees)
    end
end

function Base.show(io::IO, c::CurrencyCash{<:Cash,E}) where {E<:ExchangeID}
    write(io, "$(c.cash) (on $(E.parameters[1]))")
end
Base.hash(c::CurrencyCash, args...) = hash(c.cash, args...)
Base.nameof(c::CurrencyCash) = nameof(c.cash)

Base.promote(c::CurrencyCash, n) = promote(c.cash, n)
Base.promote(n, c::CurrencyCash) = promote(n, c.cash)

Base.convert(::Type{T}, c::CurrencyCash) where {T<:Real} = convert(T, c.cash)
Base.isless(a::CurrencyCash, b::CurrencyCash) = isless(a.cash, b.cash)
Base.isless(a::CurrencyCash, b::Number) = isless(promote(a, b)...)
Base.isless(b::Number, a::CurrencyCash) = isless(promote(b, a)...)

Base.abs(c::CurrencyCash) = abs(c.cash)
Base.real(c::CurrencyCash) = real(c.cash)

-(a::CurrencyCash, b::Real) = a.cash - b
÷(a::CurrencyCash, b::Real) = a.cash ÷ b

==(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = b.cash == a.cash
÷(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = a.cash ÷ b.cash
*(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = a.cash * b.cash
/(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = a.cash / b.cash
+(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = a.cash + b.cash
-(a::CurrencyCash{S}, b::CurrencyCash{S}) where {S} = a.cash - b.cash

add!(c::CurrencyCash, v) = add!(c.cash, v)
sub!(c::CurrencyCash, v) = sub!(c.cash, v)
@doc "Never subtract below zero."
subzero!(c::CurrencyCash, v) = subzero!(c.cash, v)
mul!(c::CurrencyCash, v) = mul!(c.cash, v)
rdiv!(c::CurrencyCash, v) = rdiv!(c.cash, v)
div!(c::CurrencyCash, v) = div!(c.cash, v)
mod!(c::CurrencyCash, v) = mod!(c.cash, v)
cash!(c::CurrencyCash, v) = cash!(c.cash, v)
