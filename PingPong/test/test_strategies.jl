_strategies_1() = begin
end

function test_strategies()
    @eval begin
        using TimeTicks
        using PingPong.Engine.Simulations: Simulations as sim
        using Data: Data as da
    end

    @testset "strategies" begin
        @test begin
            @eval using PingPong.Engine
            cfg::Config = Config(Symbol(exc.id))
            s = strategy!(:Example, cfg)
            [k.raw for k in s.universe.data.asset] == ["ETH/USDT", "BTC/USDT", "XMR/USDT"]
        end
    end
end
