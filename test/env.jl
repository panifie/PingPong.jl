using PingPong
using TimeTicks
using Instruments
using Instruments.Derivatives
using PingPong.Engine: Engine, Strategies as strat
using PingPong.Engine.Types: Collections as co, Instances as ista
using Data: Data as da, DFUtils as dfu
using Processing: Processing as pro
using Misc: Misc as mi
using Lang: @m_str

const egn = Engine
const istr = Instruments
const der = Derivatives
const sim = Engine.Simulations

setexchange!(:kucoinfutures)
cfg = loadconfig!(nameof(exc.id); cfg=Config())

function loadbtc()
    @eval begin
        s = loadstrategy!(:Example, cfg)
        fill!(s.universe, config.timeframes[(begin + 1):end]...)
        btc = s.universe[d"BTC/USDT:USDT"].instance[1]
    end
end

function dostub!(pairs=["eth", "btc", "xmr"])
    @eval using Scrapers: Scrapers as scr
    GC.gc()
    data = invokelatest(scr.BinanceData.binanceload, pairs)
    co.stub!(s.universe, data)
end
