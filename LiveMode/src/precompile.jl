using .Misc.Lang: Lang, @preset, @precomp, @m_str, @ignore

@preset let
    st.Instances.Exchanges.Python.py_start_loop()
    s = st.strategy(st.BareStrat; mode=Live())
    sim = SimMode.sim
    for ai in s.universe
        append!(
            ohlcv_dict(ai)[s.timeframe],
            sim.Processing.Data.to_ohlcv(sim.synthohlcv());
            cols=:union,
        )
    end
    sim.Random.seed!(1)
    ai = first(s.universe)
    amount = ai.limits.amount.min
    date = now()
    price = ai.limits.price.min * 2
    @precomp @ignore begin
        start!(s)
        stop!(s)
    end
    ot = OrderTypes
    start!(s)
    SimMode.@compile_pong
    @precomp @ignore begin
        stop!(s)
        reset!(s)
    end
    stop!(s)
    st.Instances.Exchanges.ExchangeTypes._closeall()
    st.Instances.Exchanges.Python.py_stop_loop()
end