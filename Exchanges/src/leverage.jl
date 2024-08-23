using .Python: PyException, pyisTrue, pygetitem, pyeq, @py, pyfetch_timeout
using Data: Cache, tobytes, todata
using Data.DataStructures: SortedDict
using Instruments: splitpair
using .Misc: IsolatedMargin, CrossMargin, Long, Short
import .Misc.marginmode

# TODO: export to livemode
resp_code(resp, ::Type{<:ExchangeID}) = pygetitem(resp, @pyconst("code"), @pyconst(""))
function _handle_leverage(e::Exchange, resp)
    if resp isa PyException
        if occursin("not modified", string(resp))
            true
        else
            @warn "exchanges: set leverage error" e resp
            false
        end
    else
        resptobool(e, resp)
    end
end

leverage_value(::Exchange, val, sym) = string(round(float(val), digits=2))
@doc "Update the leverage for a specific symbol.

$(TYPEDSIGNATURES)

- `exc`: an Exchange object to update the leverage on.
- `v`: a Real number representing the new leverage value.
- `sym`: a string representing the symbol to update the leverage for.
"
function leverage!(exc::Exchange, v, sym; side=Long(), timeout=Second(5))
    lev = leverage_value(exc, v, sym)
    set_func = first(exc, :setLeverage)
    if isnothing(set_func)
        @warn "exchanges: set leverage not supported" exc
        return false
    end
    resp = pyfetch_timeout(set_func, Returns(nothing), timeout, lev, sym)
    if isnothing(resp)
        @warn "exchanges: set leverage timedout" sym lev = v exc
        false
    else
        success = _handle_leverage(exc, resp)
        if !success
            # TODO: support `fetchLeverages` with caching?
            fetch_func = first(exc, :fetchLeverage)
            if isnothing(fetch_func)
                @warn "exchange: can't check leverage" exc
                return false
            end
            resp_lev = pyfetch_timeout(fetch_func, Returns(nothing), timeout, sym)
            if isnothing(resp_lev)
                false
            elseif resp_lev isa Exception
                @error "exchanges: set leverage" exception = resp_lev
                false
            else
                side_key = ifelse(side == Long(), "longLeverage", "shortLeverage")
                resp_val = pytofloat(get(resp_lev, side_key, Base.NaN))
                pytofloat(lev) == resp_val
            end
        else
            true
        end
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

function dosetmargin(exc::Exchange, mode_str, symbol; kwargs...)
    resp = pyfetch(exc.setMarginMode, mode_str, symbol)
    resptobool(exc, resp)
end

@doc "Update margin mode for a specific symbol on the exchange.

Also sets if the position is hedged or one sided.
For customizations, dispatch to `dosetmargin`.

$(TYPEDSIGNATURES)
"
function marginmode!(exc::Exchange, mode, symbol; hedged=false, kwargs...)
    mode_str = string(mode)
    if mode_str in ("isolated", "cross")
        exc.options["defaultMarginMode"] = mode_str
        if !isempty(symbol)
            ans = dosetmargin(exc, mode_str, symbol; hedged, kwargs...)
            if ans isa Bool
                return ans
            else
                @error "failed to set margin mode" exc = nameof(exc) err = ans
                return false
            end
        else
            return true
        end
    elseif mode_str == "nomargin"
        return true
    else
        error("Invalid margin mode $mode")
    end
end

marginmode(exc::Exchange) = get(exc.options, "defaultMarginMode", NoMargin())
