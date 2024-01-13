using .Misc.Lang: Lang, @preset, @precomp, @m_str, @ignore

@preset let
    ENV["JULIA_DEBUG"] = "LiveMode"
    st.Instances.Exchanges.Python.py_start_loop()
    run_funcs(exchange, margin) = begin
        s = st.strategy(st.BareStrat; mode=Live(), exchange, margin)
        exc_live_funcs!(s)
        sml = SimMode.sml
        @info "PRECOMP: live mode ohlcv" exchange margin
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
        @info "PRECOMP: live mode start stop" exchange margin
        @precomp begin
            start!(s)
            stop!(s)
        end
        ot = OrderTypes
        @info "PRECOMP: live mode pong" exchange margin
        start!(s)
        SimMode.@compile_pong

        start!(s)
        @info "PRECOMP: live mode reset" exchange margin
        @precomp @ignore begin
            stop!(s)
            reset!(s)
        end
        stop!(s)
    end
    @sync begin
        @async run_funcs(:gateio, st.Isolated())
        @async run_funcs(:phemex, st.NoMargin())
    end
    st.Instances.Exchanges.ExchangeTypes._closeall()
    st.Instances.Exchanges.Python.py_stop_loop()
end
