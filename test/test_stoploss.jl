using Test

function _stoploss_1()
    cdl = da.Candle(; timestamp=DateTime(0), open=3, high=4, low=1.2, close=2, volume=0)
    targets = (2.0, 1.2, 0.5)
    expected = (true, true, false)
    @test all([sim.isstoploss(cdl, t) for t in targets] .== expected)
end

function _stoploss_2()
    stop = sim.Stoploss(0.02)
    @test stop.loss == 0.02
    @test stop.loss_target ≈ 1 - 0.02
    @test isnan(stop.trailing_loss)
    @test isnan(stop.trailing_loss_target)
    stop = sim.Stoploss(0.02, 0.005, 0.03)
    @test stop.trailing_loss == 0.005
    @test stop.trailing_loss_target ≈ 1.0 - 0.005
    @test stop.trailing_offset ≈ 0.03

    stop = sim.Stoploss(0.02)
    @test sim.stopat(1., stop) ≈ 0.02
    @test sim.stopat(0., stop) == 0
    @test sim.stopat(0.5, stop) ≈ 0.01
end

test_stoploss() = @testset "stoploss" begin
    @eval begin
        using TimeTicks
        using PingPong.Engine.Sim: Sim as sim
        using Data: Data as da
    end
    _stoploss_1()
    _stoploss_2()
end
