using Python: PyException, pyisTrue, pygetitem, pyeq, @py
using Data: Cache, tobytes, todata
using Data.DataStructures: SortedDict
using Instruments: splitpair
using Misc: IsolatedMargin, CrossMargin

_handle_leverage(resp) = begin
    if resp isa PyException
        @debug resp
        false
    else
        pyeq(Bool, pygetitem(resp, @pystr("code"), @pystr("")), @pystr("0"))
    end
end


@doc "Update leverage for a specific symbol. Returns `true` on success, `false` otherwise."
function leverage!(exc::Exchange, v::Real, sym::AbstractString)
    resp = pyfetch(exc.setLeverage, Val(:try), v, sym)
    _handle_leverage(resp)
end

@kwdef struct LeverageTier{T<:Real}
    min_notional::T
    max_notional::T
    max_leverage::T
    tier::Int
    mmr::T
    bc::Symbol
end
LeverageTier(args...; kwargs...) = LeverageTier{Float64}(args...; kwargs...)
const LeverageTiersDict = SortedDict{Int,LeverageTier}
const leverageTiersCache = Dict{String,LeverageTiersDict}()
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

function tier(tiers::SortedDict{Int,LeverageTier}, size::Real)
    idx = findfirst(t -> t.max_notional > abs(size), tiers)
    idx, tiers[@something idx lastindex(tiers)]
end

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

function marginmode!(exc::Exchange, mode, symbol)
    mode_str = string(mode)
    if mode_str in ("isolated", "cross")
        dosetmargin(exc, mode_str, symbol)
    elseif mode_str == "nomargin"
    else
        error("Invalid margin mode $mode")
    end
end
