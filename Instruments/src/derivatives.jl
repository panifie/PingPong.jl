module Derivatives
using ..Instruments
using ..Instruments: FULL_SYMBOL_GROUPS_REGEX

@doc "A symbol parsed as settlement currency."
const SettlementCurrency = Symbol
@doc "Differentiates between perpetuals and options."
@enum DerivativeKind Unkn Call Put
parse_option(s::AbstractString) = begin
    s == "C" && return Call
    s == "P" && return Put
    throw(ArgumentError("Failed to parse $s as `DerivativeKind`."))
end

_derivative_error(s) = "Failed to parse derivative symbols for $s."

@doc """Derivative parsed accordingly to [`regex`](@ref Instruments.FULL_SYMBOL_GROUPS_REGEX).

- `asset`: The underlying asset.
- `sc`: settlement currency.
- `id`: identifier of the contract (the date).
- `strike`: strike price.
- `kind`: [`Instruments.Derivatives.DerivativeKind`](@ref)
"""
struct Derivative2{A<:Asset} <: AbstractAsset
    asset::A
    sc::SettlementCurrency
    id::SubString
    strike::Float64
    kind::DerivativeKind
    function Derivative2(a::A, args...; kwargs...) where {A<:Asset}
        new{A}(a, args...; kwargs...)
    end
    function Derivative2(s::AbstractString, m)
        asset = Asset(SubString(s, 1, length(s)), m[1], m[2])
        @assert !isnothing(m[3]) _derivative_error(s)
        S = Symbol(m[3])
        id = isnothing(m[4]) ? SubString("") : m[4]
        strike = isnothing(m[5]) || isempty(m[5]) ? 0.0 : parse(Float64, m[5])
        kind = isnothing(m[6]) || isempty(m[6]) ? Unkn : parse_option(m[6])
        Derivative2(asset, S, id, strike, kind)
    end
end
Derivative = Derivative2

function perpetual(raw::AbstractString, bc, qc)
    Derivative(Asset(SubString(raw), bc, qc), Symbol(qc), SubString(""), 0.0, Unkn)
end

function Base.parse(::Type{Derivative}, s::AbstractString)
    m = match(FULL_SYMBOL_GROUPS_REGEX, s)
    @assert !(isnothing(m) || isnothing(m.captures)) _derivative_error(s)
    Derivative(s, m.captures)
end

function Base.parse(::Type{AbstractAsset}, s::AbstractString)
    m = match(FULL_SYMBOL_GROUPS_REGEX, s)
    @assert !(isnothing(m) || isnothing(m.captures)) _derivative_error(s)
    if length(m) > 2 && !isempty(m[3])
        Derivative(s, m.captures)
    else
        Asset(SubString(s, 1, length(s)), m[1], m[2])
    end
end

import Base.getproperty
function getproperty(d::Derivative, s::Symbol)
    s ∈ fieldnames(Asset) && return getproperty(getfield(d, :asset), s)
    getfield(d, s)
end

@doc "Predicates according to [OctoBot](https://github.com/Drakkar-Software/OctoBot-Commons/blob/master/octobot_commons/symbols/symbol.py)"
is_settled(d::Derivative) = d.sc != Symbol()
has_strike(d::Derivative) = d.strike != 0.0
expires(d::Derivative) = !isempty(d.id)
# FIXME: `is_future` doesn't make sense. If anything it should be `is_derivative`. But we could also
# raise an error inside the `Derivative` constructor when we can't parse the settlement currency.
is_future(d::Derivative) = is_settled(d) && !has_strike(d) && d.kind == Unkn
is_perp(d::Derivative) = is_future(d) && !expires(d.id)
is_spot(d::Derivative) = !is_settled(d)
is_option(d::Derivative) =
    d.kind != Unkn && is_settled(d) && has_strike(d) && expires(d)
is_linear(d::Derivative) = is_settled(d) ? d.qc == d.sc : true
is_inverse(d::Derivative) = is_settled(d) ? d.bc == d.sc : false

@doc """Shortand for parsing derivatives:
```julia
> drv = d"BTC/USDT:USDT"
> typeof(drv)
# Instruments.Derivatives.Derivative{Asset{:BTC, :USDT}}
```
"""
macro d_str(s)
    :($(parse(Derivative, s)))
end

export Derivative, DerivativeKind, @d_str, perpetual

end
