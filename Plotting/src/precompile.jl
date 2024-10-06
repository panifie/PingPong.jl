using .Lang: @preset, @precomp
@preset let
    using Metrics.Stubs

    st.Instances.Exchanges.Python.py_start_loop()
    s = Stubs.stub_strategy(; dostub=false)
    Stubs.gensave_trades(; s, dosave=false)
    ai = first(s.universe)
    ohlcv_1d = resample(ai.ohlcv, tf"1d")
    r_len = size(ohlcv_1d, 1)
    r1 = rand(-1:0.001:1, r_len) .+ ohlcv_1d.high
    r2 = rand(-1:0.001:1, r_len) .+ ohlcv_1d.low
    @precomp begin
        ohlcv(ai.ohlcv, tf"1d")
        line_indicator(ai.ohlcv, r1, r2)
        channel_indicator(ai.ohlcv, r1, r2)
        tradesticks(s)
        balloons(s, ai; tf=tf"1d")
        balloons(s; tf=tf"1d")
    end
    st.Instances.Exchanges.Python.py_stop_loop()
end
