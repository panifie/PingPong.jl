using PingPong.Engine: Engine, Strategies as strat, Collections, Instances, Instruments as inst
using Scrapers: Scrapers as scr

setexchange!(:bybit)
cfg = loadconfig!(nameof(exc.id); cfg=Config())
s = loadstrategy!(:Example, cfg)
btc = s.universe[d"BTC/USDT:USDT"].instance[1]
# fill!(s.universe, config.timeframes[(begin + 1):end]...)
let data = scr.BinanceData.binanceload()
    stub!(s.universe, data)
end
