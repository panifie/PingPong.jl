@doc """
Copies OHLCV data from one strategy instance to another.

$(TYPEDSIGNATURES)

Ensures that the destination strategy's asset instances are updated with the source's OHLCV data for matching market symbols.
"""
function copyohlcv!(s_dst::T, s_src::T) where {T<:Strategy}
    syms_to = marketsid(s_dst)
    dst_ai = Dict(raw(ai) => ai for ai in s_dst.universe)
    for ai in s_src.universe
        if raw(ai) ∈ syms_to
            for (tf, ov) in ai.data
                dst_ai[raw(ai)].data[tf] = ov
            end
        end
    end
end

@doc """
Updates the OHLCV data for a destination asset instance from a source.

$(TYPEDSIGNATURES)

Existing OHLCV data for the destination is cleared before copying to ensure accurate and up-to-date information.
"""
function copyohlcv!(ai_dst::T1, ai_src::T2) where {T1,T2<:AssetInstance}
    dst_data, src_data = (ohlcv_dict(ai_dst), ohlcv_dict(ai_src))
    for (tf, data) in src_data
        dst_ohlcv = get(dst_data, tf, missing)
        if !ismissing(dst_ohlcv)
            if !isempty(dst_ohlcv)
                empty!(dst_ohlcv)
            end
            append!(dst_ohlcv, data)
        end
    end
end

@doc """ Waits for OHLCV data to update up to a specified time.

$(TYPEDSIGNATURES)

The function continuously checks if the latest data in each asset's time frame is up-to-date with the `since` parameter.
It pauses execution using `sleep` for the given `interval` until the condition is met.
"""
function waitohlcv(s, since; interval=Second(1))
    for ai in s.universe
        for (tf, ov) in ai.data
            while true
                if !isempty(ov)
                    if islast(lastdate(ov), tf) && firstdate(ov) <= since
                        break
                    end
                end
                sleep(interval)
            end
        end
    end
end

@doc """
Determines if the OHLCV data is stale for a simulation strategy.

$(TYPEDSIGNATURES)

For a simulation strategy it is always up-to-date, so always returns `false`.
"""
isstaleohlcv(s::SimStrategy, args...; kwargs...) = false
@doc """
Determines if the OHLCV data is stale for specified conditions.

$(TYPEDSIGNATURES)

The function checks whether the latest time stamp of OHLCV data is not older than the backoff period.
If older, it returns `true`, indicating the data is stale. Used to avoid reprocessing the same ohlcv candle.
"""
function isstaleohlcv(s::RTStrategy, ai; ats, tf, backoff)
    islast, last_date = islastts(s, ai, ats, tf)
    if islast
        if last_date > backoff[ai]
            backoff[ai] = last_date
        else
            @debug "surge: candle already processed" ai maxlog = 1 backoff[ai]
            return true
        end
    else
        @debug "surge: missing ohlcv" ai
        return true
    end
    return false
end
