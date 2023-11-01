using .Lang: @preset, @precomp, @m_str, @ignore

include("precompile_pong.jl")

@preset let
    st.Instances.Exchanges.Python.py_start_loop()
    s = st.strategy(st.BareStrat)
    @precomp begin
        ohlcv_dict(s[m"btc"])[s.timeframe]
        empty_ohlcv()
    end
    for ai in s.universe
        append!(
            ohlcv_dict(ai)[s.timeframe],
            sim.Processing.Data.to_ohlcv(sim.synthohlcv());
            cols=:union,
        )
    end
    sim.Random.seed!(1)
    mod = s.self
    @precomp @ignore begin
        start!(s)
        start!(s, ect.Context(now() - Year(1), tf"1d", Year(1)))
        start!(s; doreset=false)
    end
    @compile_pong
    st.Instances.Exchanges.Python.py_stop_loop()
end
