using .Misc.Lang: Lang, @preset, @precomp, @m_str, @ignore

@preset let
    ENV["JULIA_DEBUG"] = "LiveMode"
    st.Instances.Exchanges.Python.py_start_loop()
    run_funcs(exchange, margin) = begin
        s = st.strategy(st.BareStrat; mode=Live(), exchange, margin)
        s[:sync_history_limit] = 0
        exc_live_funcs!(s)
        sml = SimMode.sml
        @debug "PRECOMP: live mode ohlcv" exchange margin jobs = get(ENV, "JULIA_NUM_THREADS", 1)
        for ai in s.universe
            append!(
                ohlcv_dict(ai)[s.timeframe],
                sml.Processing.Data.to_ohlcv(sml.synthohlcv());
                cols=:union,
            )
        end
        sml.Random.seed!(1)
        ai = first(s.universe)
        amount = ai.limits.amount.min
        date = now()
        price = ai.limits.price.min * 2
        @debug "PRECOMP: live mode start stop" exchange margin
        @precomp begin
            @info "PRECOMP: start" exchange margin
            start!(s)
            @info "PRECOMP: stop" exchange margin
            stop!(s)
            @info "PRECOMP: stopped" exchange margin
        end
        ot = OrderTypes
        @debug "PRECOMP: live mode pong" exchange margin
        start!(s)
        SimMode.@compile_pong

        start!(s)
        @debug "PRECOMP: live mode reset" exchange margin
        @precomp @ignore begin
            stop!(s)
            reset!(s)
        end
        stop!(s)
    end
    try
        @sync begin
            @async run_funcs(:deribit, st.Isolated())
            @async run_funcs(:phemex, st.NoMargin())
        end
    catch e
        @error exception = e
    end
    @debug "PRECOMP: live mode closing"
    st.Instances.Exchanges.ExchangeTypes._closeall()
    st.Instances.Exchanges.Python.py_stop_loop()
end
