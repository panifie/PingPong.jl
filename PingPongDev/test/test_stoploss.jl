using Test

function _stoploss_1()
    cdl = da.Candle(; timestamp=DateTime(0), open=3, high=4, low=1.2, close=2, volume=0)
    targets = (2.0, 1.2, 0.5)
    expected = (true, true, false)
    @test all([sml.triggered(cdl, t) for t in targets] .== expected)
end

function _stoploss_2()
    stop = sml.Stoploss(0.02)
    @info "TEST stop1" stop
    @test stop.loss == 0.02
    @test stop.loss_target ≈ 1 - 0.02
    @test isnan(stop.trailing_loss)
    @test isnan(stop.trailing_loss_target)
    stop = sml.Stoploss(0.02, 0.005, 0.03)
    @info "TEST stop2" stop
    @test stop.trailing_loss == 0.005
    @test stop.trailing_loss_target ≈ 1.0 - 0.005
    @test stop.trailing_offset ≈ 0.03

    stop = sml.Stoploss(0.02)
    @info "TEST stop3" stop.loss stop.loss_target
    @test sml.stopat(1.0, stop) ≈ 0.98
    @test sml.stopat(0.0, stop) == 0
    @test sml.stopat(0.5, stop) ≈ 0.49
end

test_stoploss() = begin
    @eval begin
        using TimeTicks
        using .PingPong.Engine.Simulations: Simulations as sml
        using Data: Data as da
    end
    @testset failfast = FAILFAST "stoploss" begin
        _stoploss_1()
        _stoploss_2()
    end
end
