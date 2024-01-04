using .Misc.Lang: Lang, @preset, @precomp, @m_str, @ignore

@preset let
    ENV["JULIA_DEBUG"] = "LiveMode"
    st.Instances.Exchanges.Python.py_start_loop()
    s = st.strategy(st.BareStrat; mode=Live())
    exc_live_funcs!(s)
    sml = SimMode.sml
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
    @precomp begin
        start!(s)
        stop!(s)
    end
    ot = OrderTypes
    start!(s)
    SimMode.@compile_pong
    SimMode.@compile_pong # HACK: if not called twice, some IO tasks are left running which stalls precompilation, should be debugged

    @precomp @ignore begin
        stop!(s)
        reset!(s)
    end
    stop!(s)
    st.Instances.Exchanges.ExchangeTypes._closeall()
    st.Instances.Exchanges.Python.py_stop_loop()
end
