using .Python: PyException, pyisTrue, pygetitem, pyeq, @py, pyfetch_timeout
using Data: Cache, tobytes, todata
using Data.DataStructures: SortedDict
using Instruments: splitpair
using .Misc: IsolatedMargin, CrossMargin

# TODO: export to livemode
resp_code(resp, ::Type{<:ExchangeID}) = pygetitem(resp, @pyconst("code"), @pyconst(""))
function _handle_leverage(e::Exchange, resp)
    if resp isa PyException
        @debug resp
        occursin("not modified", string(resp))
    else
        pyeq(Bool, resp_code(resp, typeof(e.id)), @pyconst("0"))
    end
end

@doc "Update the leverage for a specific symbol.

$(TYPEDSIGNATURES)

- `exc`: an Exchange object to update the leverage on.
- `v`: a Real number representing the new leverage value.
- `sym`: a string representing the symbol to update the leverage for.
"
function leverage!(exc::Exchange, v::Real, sym::AbstractString)
    resp = pyfetch_timeout(exc.setLeverage, Returns(nothing), Second(3), v, sym)
    if isnothing(resp)
        @warn "exchanges: set leverage timedout" sym lev = v exc = nameof(exc)
        false
    else
        _handle_leverage(exc, resp)
    end
end

@doc """A type representing a tier of leverage.

$(FIELDS)

This type is used to store and manage information about a specific leverage tier. Each tier is defined by its minimum and maximum notional values, maximum leverage, tier number, and maintenance margin requirement.
"""
@kwdef struct LeverageTier{T<:Real}
    min_notional::T
    max_notional::T
    max_leverage::T
    tier::Int
    mmr::T
    bc::Symbol
end
LeverageTier(args...; kwargs...) = LeverageTier{Float64}(args...; kwargs...)
@doc "Every asset has a list of leverage tiers, that are stored in a SortedDict, if the exchange supports them."
const LeverageTiersDict = SortedDict{Int,LeverageTier}
@doc "Leverage tiers are cached both in RAM and storage."
const leverageTiersCache = Dict{String,LeverageTiersDict}()
@doc """Returns a default leverage tier for a specific symbol.

$(TYPEDSIGNATURES)

The default leverage tier has generous limits.
"""
function default_leverage_tier(sym)
    SortedDict(
        1 => LeverageTier(;
            min_notional=1e-8,
            max_notional=2e6,
            max_leverage=100.0,
            tier=1,
            mmr=0.005,
            bc=Symbol(string(splitpair(sym)[1])),
        ),
    )
end

_tierskey(exc, sym) = "$(exc.name)/$(sym)"
@doc """Fetch the leverage tiers for a specific symbol from an exchange.

$(TYPEDSIGNATURES)

- `exc`: an Exchange object to fetch the leverage tiers from.
- `sym`: a string representing the symbol to fetch the leverage tiers for.
"""
function leverage_tiers(exc::Exchange, sym::AbstractString)
    k = _tierskey(exc, sym)
    @lget! leverageTiersCache k begin
        ans = Cache.load_cache(k; raise=false)
        if isnothing(ans)
            pytiers = pyfetch(exc.fetchMarketLeverageTiers, Val(:try), sym)
            if pytiers isa PyException || isnothing(pytiers)
                @warn "Couldn't fetch leverage tiers for $sym from $(exc.name). Using defaults. ($pytiers)"
                ans = default_leverage_tier(sym)
            else
                tiers = pyconvert(Vector{Dict{String,Any}}, pytiers)
                ans = SortedDict{Int,LeverageTier}(
                    let tier = pyconvert(Int, t["tier"])
                        delete!(t, "info")
                        tier => LeverageTier(;
                            min_notional=t["minNotional"],
                            max_notional=t["maxNotional"],
                            max_leverage=something(t["maxLeverage"], 100.0),
                            tier,
                            mmr=t["maintenanceMarginRate"],
                            bc=Symbol(t["currency"]),
                        )
                    end for t in tiers
                )
            end
            Cache.save_cache(k, ans)
        end
        ans
    end
end

@doc """Get the leverage tier for a specific size from a sorted dictionary of tiers.

$(TYPEDSIGNATURES)

- `tiers`: a SortedDict where the keys are integers representing the size thresholds and the values are LeverageTier objects.
- `size`: a Real number representing the size to fetch the tier for.

"""
function tier(tiers::SortedDict{Int,LeverageTier}, size::Real)
    idx = findfirst(t -> t.max_notional > abs(size), tiers)
    idx, tiers[@something idx lastindex(tiers)]
end

@doc """Get the maximum leverage for a specific size and symbol from an exchange.

$(TYPEDSIGNATURES)

- `exc`: an Exchange object to fetch the maximum leverage from.
- `sym`: a string representing the symbol to fetch the maximum leverage for.
- `size`: a Real number representing the size to fetch the maximum leverage for.

"""
function maxleverage(exc::Exchange, sym::AbstractString, size::Real)
    tiers = leverage_tiers(exc, sym)
    _, t = tier(tiers, size)
    t.max_leverage
end

# CCXT strings
Base.string(::Union{T,Type{T}}) where {T<:IsolatedMargin} = "isolated"
Base.string(::Union{T,Type{T}}) where {T<:CrossMargin} = "cross"
Base.string(::Union{T,Type{T}}) where {T<:NoMargin} = "nomargin"

function dosetmargin(exc::Exchange, mode_str, symbol)
    pyfetch(exc.setMarginMode, mode_str, symbol)
end

@doc "Update margin mode for a specific symbol on the exchange.

$(TYPEDSIGNATURES)
"
function marginmode!(exc::Exchange, mode, symbol)
    mode_str = string(mode)
    if mode_str in ("isolated", "cross")
        dosetmargin(exc, mode_str, symbol)
    elseif mode_str == "nomargin"
    else
        error("Invalid margin mode $mode")
    end
end
