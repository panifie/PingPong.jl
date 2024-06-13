@doc """
Initializes warmup attributes for a strategy.

$(TYPEDSIGNATURES)
"""
function initwarmup!(s; timeout=Minute(15))
    attrs = s.attrs
    attrs[:warmup] = Dict(ai => false for ai in s.universe)
    attrs[:warmup_lock] = ReentrantLock()
    attrs[:warmup_timeout] = timeout
    attrs[:warmup_candles] = 999
end
@doc """
Placeholder for simulation strategy warmup.

$(TYPEDSIGNATURES)
"""
function warmup!(cb::Function, s::SimStrategy, args...; kwargs...)
    nothing
end
@doc """
Initiates the warmup process for a real-time strategy instance.

$(TYPEDSIGNATURES)

If warmup has not been previously completed for the given asset instance, it performs the necessary preparations.
"""
function warmup!(cb::Function, s::RTStrategy, ai, ats, n_candles=s.warmup_candles)
    # give up on warmup after `warmup_timeout`
    if now() - s.is_start < s.warmup_timeout
        if !s[:warmup][ai]
            warmup_lock = @lock s @lget! s.attrs :warmup_lock ReentrantLock()
            @lock warmup_lock _warmup!(cb, s, ai, ats; n_candles)
        end
    end
end

@doc """
Executes the warmup routine with a custom callback for a strategy.

$(TYPEDSIGNATURES)

The function prepares the trading strategy by simulating past data before live execution starts.
"""
function _warmup!(
    callback::Function, s::Strategy, ai::AssetInstance, ats::DateTime; n_candles=s.warmup_candles
)
    # wait until ohlcv data is available
    @debug "warmup: checking ohlcv data"
    since = ats - s.timeframe * n_candles
    for ohlcv in values(ohlcv_dict(ai))
        if dateindex(ohlcv, since) < 1
            @warn "warmup: no data" ai = raw(ai) ats
            return nothing
        end
    end
    s_sim = @lget! s.attrs :simstrat strategy(nameof(s), mode=Sim())
    ai_dict = @lget! s.attrs :siminstances Dict(raw(ai) => ai for ai in s_sim.universe)
    ai_sim = ai_dict[raw(ai)]
    copyohlcv!(ai_sim, ai)
    uni_df = s_sim.universe.data
    empty!(uni_df)
    push!(uni_df, (exchangeid(ai_sim)(), ai_sim.asset, ai_sim))
    @assert nrow(s_sim.universe.data) == 1
    # run sim
    @debug "warmup: running sim"
    ctx = Context(Sim(), s.timeframe, since, since + s.timeframe * n_candles)
    start!(s_sim, ctx)
    # callback
    callback(s, ai, s_sim, ai_sim)
    @debug "warmup: completed" ai = raw(ai)
end
