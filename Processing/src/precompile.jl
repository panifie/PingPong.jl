using .Lang: PrecompileTools, @preset, @precomp

@preset let
    using Data: Data as da
    path = joinpath(@__DIR__, "../../PingPong/test/stubs/ohlcv.jls")
    df = read(path) |> da.todata
    @precomp begin
        resample(df, tf"1d")
        normalize!([1.0, 2, 3]; unit=true)
        normalize!([1.0, 2, 3]; unit=false)
        trail!(df, timeframe(df); to=(lastdate(df) + tf"1m" * 3))
        cleanup_ohlcv_data(df, timeframe(df))
        isincomplete(dt"2020-01-01", tf"1m")
        islast("2020-01-01", "1d")
        islast(da.default(Candle), tf"1d")
        isadjacent(dt"2020-01-02", dt"2020-01-01", tf"1d")
    end
end
