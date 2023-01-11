module Pairs

using Misc: PairData

@doc "A symbol checked to be a valid quote currency."
const QuoteCurrency = Symbol
@doc "A symbol checked to be a valid base currency."
const BaseCurrency = Symbol

include("consts.jl")

has_punct(s::AbstractString) = !isnothing(match(r"[[:punct:]]", s))

struct Asset{B,Q}
    raw::SubString
    bc::BaseCurrency
    qc::QuoteCurrency
    fiat::Bool
    leveraged::Bool
    unleveraged_bc::BaseCurrency
    Asset(s::T) where {T<:AbstractString} = begin
        pair = split_pair(s)
        if length(pair) > 2 || has_punct(pair[1]) || has_punct(pair[2])
            throw(InexactError(:Asset, Asset, s))
        end
        B = Symbol(pair[1])
        Q = Symbol(pair[2])
        fiat = is_fiat_pair(pair)
        lev = is_leveraged_pair(s)
        unlev = deleverage_pair(pair)
        new{B,Q}(SubString(s, 1, length(s)), B, Q, fiat, lev, Symbol(unlev))
    end
end

Base.hash(a::Asset, h::UInt) = Base.hash((a.bc, a.qc), h)
Base.convert(::Type{String}, a::Asset) = a.raw
Base.display(a::Asset) = Base.display(a.raw)
Base.show(a::Asset) = Base.display(a.raw)
Base.display(v::AbstractVector{T}) where {T<:Asset} = begin
    text = Vector{String}()
    for a in v
        push!(text, a.raw)
    end
    Base.display(text)
end

const QuoteTuple = @NamedTuple{q::Symbol}
const BaseTuple = @NamedTuple{b::Symbol}
const BaseQuoteTuple = @NamedTuple{b::Symbol, q::Symbol}
const CurrencyTuple = Union{QuoteTuple,BaseTuple,BaseQuoteTuple}
Base.Broadcast.broadcastable(q::Asset) = Ref(q)
Base.in(a::Asset, t::QuoteTuple) = Base.isequal(a.qc, t.q)
Base.in(a::Asset, t::BaseTuple) = Base.isequal(a.bc, t.b)
Base.in(a::Asset, t::BaseQuoteTuple) = Base.isequal(a.bc, t.b) && Base.isequal(a.qc, t.q)
import Base.==
==(a::Asset, s::String) = Base.isequal(a.raw, s)

@inline isbase(a::Asset, b::Symbol) = a.bc == b
@inline isquote(a::Asset, q::Symbol) = a.qc == q

const leverage_pair_rgx =
    r"(?:(?:BULL)|(?:BEAR)|(?:[0-9]+L)|(?:[0-9]+S)|(?:UP)|(?:DOWN)|(?:[0-9]+LONG)|(?:[0-9+]SHORT))([\/\-\_\.])"

@doc "Test if pair has leveraged naming."
@inline is_leveraged_pair(pair) = !isnothing(match(leverage_pair_rgx, pair))

@inline split_pair(pair::AbstractString) = split(pair, r"\/|\-|\_|\.")

@doc "Remove leveraged pair pre/suffixes from base currency."
@inline function deleverage_pair(dlv::Vector{T}, split=false) where {T<:AbstractString}
    # HACK: assume that BEAR/BULL represent BTC
    if isempty(dlv[1])
        @warn "Deleveraging pair $pair failed, assuming pair is BTC."
        dlv[1] = "BTC"
    end
    split && dlv || join(dlv, "")
end

function deleverage_pair(pair::AbstractString; kwargs...)
    dlv = replace(pair, leverage_pair_rgx => s"\1")
    deleverage_pair(dlv; kwargs...)
end

@inline deleverage_qc(dlv::Vector{T}) where {T<:AbstractString} =
    deleverage_pair(dlv; split=true)[1]
deleverage_qc(pair::AbstractString) = deleverage_pair(pair; split=true)[1]

@doc "Check if both base and quote are fiat currencies."
@inline is_fiat_pair(p::Vector{T}) where {T<:AbstractString} =
    p[1] ∈ fiatnames && p[2] ∈ fiatnames
is_fiat_pair(pair::AbstractString) = split_pair(pair) |> is_fiat_pair

macro a_str(pair)
    :($(Asset(pair)))
end

export Asset, is_fiat_pair, deleverage_pair, is_leveraged_pair, @a_str

end # module Pairs
