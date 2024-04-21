using Lang: @lget!
using Misc: Misc
using Misc.DocStringExtensions
import Base: ==, +, -, ÷, /, *, ≈
include("cashcur.jl")

@doc "A symbol checked to be a valid quote currency."
const QuoteCurrency = Symbol
@doc "A symbol checked to be a valid base currency."
const BaseCurrency = Symbol

include("consts.jl")

@doc """Check if a string s contains any punctuation characters.

$(TYPEDSIGNATURES)

The function returns true if s contains any punctuation characters, and false otherwise.

Example:

```
s = "Hello, world!"
result = has_punct(s)  # returns true since the string contains a punctuation character
```
"""
has_punct(s::AbstractString) = !isnothing(match(r"[[:punct:]]", s))
@doc """Abstract base type for representing an asset.

Defines the interface and common functionality for all asset types.
"""
abstract type AbstractAsset end

# TYPENUM
@doc """An `Asset` represents a parsed raw (usually ccxt) pair of base and quote currency.

- `raw`: The raw underlying string e.g. 'BTC/USDT'
- `bc`: base currency (Symbol)
- `qc`: quote currency (Symbol)
- `fiat`: if both the base and quote currencies match a known fiat symbol e.g. 'USDT/USDC'
- `leveraged`: if parsing matched a leveraged token e.g. 'ETH3L/USDT' or 'ETH3S/USDT'
- `unleveraged_bc`: a leveraged token with the `mod` removed, e.g. `ETH3L` => `ETH`

```julia
> asset = a"BTC/USDT"
> typeof(asset)
Asset{:BTC, :USDT}
end
```
"""
struct Asset <: AbstractAsset
    raw::SubString
    bc::BaseCurrency
    qc::QuoteCurrency
    fiat::Bool
    leveraged::Bool
    unleveraged_bc::BaseCurrency
    function Asset(s::SubString, b::T, q::T) where {T<:AbstractString}
        B = Symbol(b)
        Q = Symbol(q)
        fiat = isfiatpair(b, q)
        lev = isleveragedpair(s)
        unlev = lev ? deleverage_pair(s; split=true)[1] : B
        new(s, B, Q, fiat, lev, Symbol(unlev))
    end
    Asset(s::AbstractString) = parse(Asset, s)
end

_check_parse(pair, s) = begin
    if length(pair) > 2 || has_punct(pair[1]) || has_punct(pair[2])
        throw(InexactError(:Asset, Asset, s))
    end
end
function Base.parse(::Type{Asset}, s::AbstractString)
    pair = splitpair(s)
    _check_parse(pair, s)
    Asset(SubString(s), pair[1], pair[2])
end
const symbol_rgx_cache = Dict{String,Regex}()
function Base.parse(
    ::Type{<:AbstractAsset}, s::AbstractString, qc::AbstractString; raise=true
)
    pair = splitpair(s)
    m = match(@lget!(symbol_rgx_cache, qc, Regex("(.*)($qc)(?:settled?)?\$", "i")), pair[1])
    if isnothing(m)
        raise && throw(InexactError(:Asset, Asset, s))
        return nothing
    end
    Asset(SubString(s), m.captures[1], m.captures[2])
end
function Base.parse(
    ::Type{<:AbstractAsset}, s::AbstractString, qcs::Union{AbstractVector,AbstractSet}
)
    for qc in qcs
        p = parse(Asset, s, qc; raise=false)
        !isnothing(p) && return p
    end
    throw(InexactError(:Asset, Asset, s))
end
_hashtuple(a::AbstractAsset) = (a.bc, a.qc)
Base.hash(a::AbstractAsset) = hash(_hashtuple(a))
Base.hash(a::AbstractAsset, h::UInt) = hash(_hashtuple(a), h)
Base.isequal(a::AbstractAsset, b::AbstractAsset) = raw(a) == raw(b)
Base.:(==)(a::AbstractAsset, b::AbstractAsset) = true
Base.convert(::Type{String}, a::AbstractAsset) = a.raw
Base.string(a::AbstractAsset) = "Asset($(a.bc)/$(a.qc))"
Base.show(buf::IO, a::AbstractAsset) = write(buf, string(a))
Base.display(a::AbstractAsset) = show(stdout, a)
raw(::Nothing) = ""
raw(v::AbstractString) = v
@doc """Convert an AbstractAsset object a to its raw representation.

$(TYPEDSIGNATURES)

The function returns a new AbstractAsset object with special characters escaped using backslashes.

Example:
```julia
a = parse("BTC/USDT")
raw(a) # returns "BTC/USDT"
```
"""
raw(a::AbstractAsset) = convert(String, a)
@doc " Returns the quote currency of `a`."
qc(a::AbstractAsset) = a.qc
@doc " Returns the base currency of `a`."
bc(a::AbstractAsset) = a.bc

const QuoteTuple = @NamedTuple{q::Symbol}
const BaseTuple = @NamedTuple{b::Symbol}
const BaseQuoteTuple = @NamedTuple{b::Symbol, q::Symbol}
const CurrencyTuple = Union{QuoteTuple,BaseTuple,BaseQuoteTuple}
Base.Broadcast.broadcastable(q::Asset) = Ref(q)
Base.in(a::Asset, t::QuoteTuple) = a.qc == t.q
Base.in(a::Asset, t::BaseTuple) = a.bc == t.b
Base.in(a::Asset, t::BaseQuoteTuple) = a.bc == t.b && a.qc == t.q
==(a::AbstractAsset, s::AbstractString) = a.raw == s
==(a::Asset, b::Asset) = a.qc == b.qc && a.bc == b.bc

isbase(a::AbstractAsset, b) = a.bc == b
isquote(a::AbstractAsset, q) = a.qc == q

@doc "A regular expression pattern used to match leveraged naming conventions in market symbols. It captures the separator used in leveraged pairs."
const leverage_pair_rgx = r"(?:(?:BULL)|(?:BEAR)|(?:[0-9]+L)|(?:[0-9]+S)|(?:UP)|(?:DOWN)|(?:[0-9]+LONG)|(?:[0-9+]SHORT))([\/\-\_\.])"

@doc "Test if pair has leveraged naming."
isleveragedpair(pair) = !isnothing(match(leverage_pair_rgx, pair))
@doc """Split a CCXT pair (symbol) pair into its base and quote currencies.

$(TYPEDSIGNATURES)

The function returns a tuple containing the base currency and quote currency.

Example:
pair = "BTC/USDT"
base, quote = splitpair(pair)  # returns ("BTC", "USDT")
"""
splitpair(pair::AbstractString) = split(pair, r"\/|\-|\_|\.")
@doc "Strips the settlement currency from a symbol."
spotpair(pair::AbstractString) = split(pair, ":")[1]

@doc "Remove leveraged pair pre/suffixes from base currency."
@inline function deleverage_pair(pair::T; split=false, sep="/") where {T<:AbstractString}
    dlv = splitpair(replace(pair, leverage_pair_rgx => s"\1"))
    # HACK: assume that BEAR/BULL represent BTC
    if isempty(dlv[1])
        @warn "Deleveraging pair $pair failed, assuming base currency is BTC."
        dlv[1] = "BTC"
    end
    split ? dlv : join(dlv, sep)
end

@doc """Remove the leverage component from a CCXT quote currency quote.

$(TYPEDSIGNATURES)

The function returns a new string with the leverage component removed.

Example:
```julia
quote = "3BTC/USDT"
deleveraged_quote = deleverage_qc(quote)  # returns "USDT"
```
"""
function deleverage_qc(dlv::Vector{T}) where {T<:AbstractString}
    deleverage_pair(dlv; split=true)[1]
end
deleverage_qc(pair::AbstractString) = deleverage_pair(pair; split=true)[1]

@doc "Check if both base and quote are fiat currencies."
isfiatpair(b::T, q::T) where {T<:AbstractString} = begin
    b ∈ fiatnames && q ∈ fiatnames
end
isfiatpair(p::Vector{T}) where {T<:AbstractString} = isfiatpair(p[1], p[2])
isfiatpair(pair::AbstractString) = isfiatpair(splitpair(pair))
@doc "Check if quote currency is a stablecoin."
isfiatquote(aa::AbstractAsset) = aa.qc ∈ fiatsyms
isfiatquote(pair::AbstractString) = isfiatquote(parse(AbstractAsset, pair))

@doc """Parses `pair` to an `Asset` type.
```julia
> typeof(a"BTC/USDT")
Instruments.Asset
"""
macro a_str(pair)
    :($(parse(Asset, pair)))
end

@doc """Rewrites `sym` as a perpetual usdt symbol.
```julia
> pusdt"btc"
BTC/USDT:USDT
```
"""
macro pusdt_str(sym)
    :($(uppercase(sym) * "/USDT:USDT"))
end

export Cash, Asset, AbstractAsset
export raw, bc, qc
export isfiatpair, deleverage_pair, isleveragedpair
export @a_str, @c_str

include("derivatives.jl")
