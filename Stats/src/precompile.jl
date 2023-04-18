using Lang: SnoopPrecompile, @preset, @precomp

SnoopPrecompile.verbose[] = true

@preset let
    using Simulations: Simulations as sim
    using SimMode: SimMode as bt
    s = st.strategy(:Example)
    for ai in s.universe
        sim.stub!(ai, 100_000)
    end
    ai = s.universe["ETH/USDT:USDT"].instance[1]
    bt.backtest(s)
    # @precomp begin
    #     resample_trades(ai)
    #     resample_trades(s)
    #     trades_balance(ai)
    #     trades_balance(s)
    # end
end
