using Test

function _test_tradesohlcv_1()
    @eval begin
        using PingPong.Misc.JSON
        using PingPong.Misc.TimeTicks
        using PingPong.Engine.Processing
        using PingPong.Engine.LiveMode.Watchers
        wi = Watchers.WatchersImpls
        pro = Processing
    end
    trades = JSON.parsefile(joinpath(dirname(Base.active_project()), "test", "stubs", "trades.json"))
    trades = wi.trades_fromdict.(trades, Val(wi.CcxtTrade))
    (df, _, _) = pro.TradesOHLCV.trades_to_ohlcv(trades, tf"1m")
    @views begin
        @test NamedTuple(df[1, :]) == (;
            timestamp=DateTime("2023-02-11T18:37:00"),
            open=21658.0,
            high=21658.0,
            low=21657.9,
            close=21658.0,
            volume=15.135999999999994,
        )
        @test NamedTuple(df[2, :]) == (;
            timestamp=DateTime("2023-02-11T18:38:00"),
            open=21657.9,
            high=21670.0,
            low=21657.9,
            close=21670.0,
            volume=58.114999999999945,
        )
        @test NamedTuple(df[3, :]) == (;
            timestamp=DateTime("2023-02-11T18:39:00"),
            open=21670.0,
            high=21671.7,
            low=21665.7,
            close=21665.7,
            volume=52.07599999999998,
        )
        @test NamedTuple(df[4, :]) == (;
            timestamp=DateTime("2023-02-11T18:40:00"),
            open=21665.7,
            high=21665.8,
            low=21661.5,
            close=21661.5,
            volume=28.878000000000004,
        )
    end
end

test_tradesohlcv() = @testset "tradesohlcv" begin
    _test_tradesohlcv_1()
end
