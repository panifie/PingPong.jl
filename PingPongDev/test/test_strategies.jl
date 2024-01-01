_strategies_load() = begin
    @eval begin
        using .PingPong.Engine.TimeTicks
        using .PingPong.Engine.Simulations: Simulations as sml
        using .PingPong.Engine.Data: Data as da
        using .PingPong.Engine
        PingPongDev.@environment!
    end
end

function test_strategies()
    _strategies_load()
    @testset "strategies" begin
        cfg = Config(exchange=Symbol(exc.id))
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
