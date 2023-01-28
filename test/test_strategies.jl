function test_strategies()
    @testset "strategies" begin
        @test begin
            @eval using PingPong.Engine
            cfg::Config = loadconfig!(Symbol(exc.id); cfg=Config())
            s = loadstrategy!(:MacdStrategy, cfg)
            [k.raw for k in s.universe.data.asset] == ["ETH/USDT", "BTC/USDT", "XMR/USDT"]
        end
    end
end
