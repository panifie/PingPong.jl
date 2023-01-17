module Derivatives
using ..Pairs
using ..Pairs: FULL_SYMBOL_GROUPS_REGEX

@doc "A symbol parsed as settlement currency."
const SettlementCurrency = Symbol
@enum DerivativeKind Perp Call Put
parse_option(s::AbstractString) = begin
    s == "C" && return Call
    s == "P" && return Put
    throw(ArgumentError("Failed to parse $s as `DerivativeKind`."))
end

_derivative_error(s) = "Failed to parse derivative symbols for $s."

@doc """Derivative parsed accordingly to [`Pairs.FULL_SYMBOL_GROUPS_REGEX`](@ref)."""
struct Derivative1{A<:Asset}
    asset::A
    sc::SettlementCurrency
    id::SubString
    strike::Float64
    kind::DerivativeKind
    Derivative1(a::A, args...; kwargs...) where {A<:Asset} = begin
        new{A}(a, args...; kwargs...)
    end
    Derivative1(s::AbstractString) = begin
        m = match(FULL_SYMBOL_GROUPS_REGEX, s)
        @assert !isnothing(m) _derivative_error(s)
        m = m.captures
        asset = Asset(SubString(s, 1, length(s)), m[1], m[2])
        @assert !isnothing(m[3]) _derivative_error(s)
        S = Symbol(m[3])
        id = isnothing(m[4]) ? SubString("") : m[4]
        strike = isnothing(m[5]) || isempty(m[5]) ? 0.0 : parse(Float64, m[5])
        kind = isnothing(m[6]) || isempty(m[6]) ? Perp : parse_option(m[6])
        Derivative1(asset, S, id, strike, kind)
    end
end
Derivative = Derivative1

import Base.getproperty
function getproperty(d::Derivative, s::Symbol)
    s ∈ fieldnames(Asset) && return getproperty(getfield(d, :asset), s)
    getfield(d, s)
end

export Derivative, DerivativeKind

end
