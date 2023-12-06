_strategies_1() = begin end

function test_strategies()
    @eval begin
        using TimeTicks
        using PingPong.Engine.Simulations: Simulations as sml
        using Data: Data as da
        using PingPong.Engine
        PingPong.@environment!
    end

    @testset "strategies" begin
        cfg = Config(Symbol(exc.id))
        @test cfg isa Config
        s = st.strategy!(:Example, cfg)
        @test s isa st.Strategy
        @test nameof(cash(s)) == :USDT
        @test execmode(s) == Sim()
        @test marginmode(s) == NoMargin()
        @test typeof(s).parameters[3] <: ExchangeID
        @test nameof(s) == :Example
        @test sort!(raw.(s.universe.data.asset)) == sort!(["ETH/USDT", "BTC/USDT", "SOL/USDT"])
    end
end
