module Derivatives
using ..Instruments
using ..Instruments: FULL_SYMBOL_GROUPS_REGEX
using ..Instruments.Misc.DocStringExtensions

@doc "A symbol parsed as settlement currency."
const SettlementCurrency = Symbol
@doc "Differentiates between perpetuals and options."
@enum DerivativeKind Unkn Call Put
function parse_option(s::AbstractString)
    s == "C" && return Call
    s == "P" && return Put
    throw(ArgumentError("Failed to parse $s as `DerivativeKind`."))
end

_derivative_error(s) = "Failed to parse derivative symbols for $s."

@doc """`Derivative` parsed accordingly to [`regex`](@ref Instruments.FULL_SYMBOL_GROUPS_REGEX).

$(FIELDS)
"""
struct Derivative8 <: AbstractAsset
    asset::Asset
    sc::SettlementCurrency
    id::SubString
    strike::Float64
    kind::DerivativeKind
    function Derivative8(a::A, args...; kwargs...) where {A<:Asset}
        new(a, args...; kwargs...)
    end
    function Derivative8(s::AbstractString, m)
        asset = Asset(SubString(s, 1, length(s)), m[1], m[2])
        @assert !isnothing(m[3]) _derivative_error(s)
        S = Symbol(m[3])
        id = isnothing(m[4]) ? SubString("") : m[4]
        strike = isnothing(m[5]) || isempty(m[5]) ? 0.0 : parse(Float64, m[5])
        kind = isnothing(m[6]) || isempty(m[6]) ? Unkn : parse_option(m[6])
        Derivative8(asset, S, id, strike, kind)
    end
end
Derivative = Derivative8

@doc """Create a `Derivative` from a raw string representation raw, base currency bc, and quote currency qc.

$(TYPEDSIGNATURES)
"""
function perpetual(raw::AbstractString, bc, qc)
    Derivative(Asset(SubString(raw), bc, qc), Symbol(qc), SubString(""), 0.0, Unkn)
end

function Base.parse(::Type{Derivative}, s::AbstractString)
    m = match(FULL_SYMBOL_GROUPS_REGEX, SubString(s))
    @assert !(isnothing(m) || isnothing(m.captures)) _derivative_error(s)
    Derivative(s, m.captures)
end

function Base.parse(::Type{AbstractAsset}, s::AbstractString)
    m = match(FULL_SYMBOL_GROUPS_REGEX, SubString(s))
    @assert !(isnothing(m) || isnothing(m.captures)) _derivative_error(s)
    if length(m) > 2 && !isempty(m[3])
        Derivative(s, m.captures)
    else
        Asset(SubString(s, 1, length(s)), m[1], m[2])
    end
end

import Base.getproperty
function getproperty(d::Derivative, s::Symbol)
    hasfield(Asset, s) && return getproperty(getfield(d, :asset), s)
    getfield(d, s)
end

@doc """Short-circuit the execution of a derivative calculation if the derivative d is zero.

$(TYPEDSIGNATURES)
"""
function sc(d::Derivative; orqc=true)
    s = getfield(d, :sc)
    isequal(s, Symbol("")) && orqc ? getfield(d, :asset).qc : s
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
is_option(d::Derivative) = d.kind != Unkn && is_settled(d) && has_strike(d) && expires(d)
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
function Base.:(==)(b::NTuple{3,Symbol}, a::Derivative)
    a.bc == b[1] && a.qc == b[2] && a.sc == b[3]
end
function Base.:(==)(a::Derivative, b::Derivative)
    a.qc == b.qc && a.bc == b.bc && a.sc == b.sc
end
Base.hash(a::Derivative) = hash(getfield(a, :asset).raw) #hash(Instruments._hashtuple(a))
Base.hash(a::Derivative, h::UInt64) = hash(getfield(a, :asset).raw, h)
Base.string(a::Derivative) = "Derivative($(a.raw))"
Base.show(buf::IO, a::Derivative) = write(buf, string(a))
Base.Broadcast.broadcastable(q::Derivative) = Ref(q)

export Derivative, DerivativeKind, @d_str, perpetual, sc

end
