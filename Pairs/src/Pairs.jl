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
    Asset(s::AbstractString) = begin
        pair = split_pair(s)
        if length(pair) > 2 || has_punct(pair[1]) || has_punct(pair[2])
            throw(InexactError(:Asset, Asset, s))
        end
        B = Symbol(pair[1])
        Q = Symbol(pair[2])
        new{B,Q}(SubString(s, 1, length(s)), B, Q)
    end
end

Base.hash(a::Asset, h::UInt) = Base.hash((a.bc, a.qc), h)
display(a::Asset) = display(a.bc * "/" * q.qc)


const leverage_pair_rgx =
    r"(?:(?:BULL)|(?:BEAR)|(?:[0-9]+L)|(?:[0-9]+S)|(?:UP)|(?:DOWN)|(?:[0-9]+LONG)|(?:[0-9+]SHORT))([\/\-\_\.])"

@doc "Test if pair has leveraged naming."
function is_leveraged_pair(pair)
    !isnothing(match(leverage_pair_rgx, pair))
end

@inline split_pair(pair::AbstractString) = split(pair, r"\/|\-|\_|\.")

@doc "Remove leveraged pair pre/suffixes from base currency."
function deleverage_pair(pair)
    dlv = replace(pair, leverage_pair_rgx => s"\1")
    # HACK: assume that BEAR/BULL represent BTC
    pair = split_pair(dlv)
    if pair[1] |> isempty
        "BTC" * dlv
    else
        dlv
    end
end

@doc "Check if both base and quote are fiat currencies."
function is_fiat_pair(pair)
    p = split_pair(pair)
    p[1] ∈ fiatnames && p[2] ∈ fiatnames
end

export Asset, is_fiat_pair, deleverage_pair, is_leveraged_pair, display, hash

end # module Pairs
