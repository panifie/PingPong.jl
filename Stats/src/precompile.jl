using Lang: SnoopPrecompile, @preset, @precomp

# FIXME: This precompilation bloats the module
# maybe we should just input the precompile statements here.
@preset let
    using Simulations: Simulations as sim
    using Data: Data as da
    using Data.DataFrames
    using Engine.Exchanges: Exchanges as exs, Instruments as im
    using Engine.Misc
    include("../../test/utils.jl")
    include("../../test/stubs/Example.jl")
    s = st.strategy!(Example, Misc.config)
    for ai in s.universe
        sim.stub!(ai, 100_000)
    end
    ai = s.universe["ETH/USDT:USDT"].instance[1]
    for ai in s.universe
        Stubs.load_stubtrades!(ai)
    end
    @precomp begin
        resample_trades(ai, tf"1d")
        resample_trades(s, tf"1d")
        trades_balance(ai; tf=tf"1d")
        trades_balance(s; tf=tf"1d")
    end
end
