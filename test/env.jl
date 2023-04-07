using PingPong
using TimeTicks
using TimeTicks: TimeTicks as tt
using Instruments
using Instruments: Instruments as istr
using Instruments.Derivatives
using Instruments.Derivatives: Derivatives as der
using PingPong.Engine: Engine as egn, Strategies as st
using PingPong.Engine.Simulations: Simulations as sim
using PingPong.Engine.Executors.Backtest: Backtest as bt
using PingPong.Engine.Types: Collections as co
using Data: Data as da, DFUtils as dfu
using Processing: Processing as pro
using Misc: Misc as mi
using Lang: @m_str

# setexchange!(:bybit)
# cfg = Config(nameof(exc.id))

function loadbtc()
    @eval begin
        s = strategy!(:Example, cfg)
        fill!(s.universe, config.timeframes[(begin + 1):end]...)
        btc = s.universe[d"BTC/USDT:USDT"].instance[1]
    end
end

function dostub!(pairs=["eth", "btc", "xmr"])
    @eval using Scrapers: Scrapers as scr
    GC.gc()
    qc = string(nameof(s.cash))
    data = invokelatest(scr.BinanceData.binanceload, pairs; quote_currency=qc)
    egn.Types.stub!(s.universe, data)
end
