using PingPong: PingPong, Exchanges
using .Exchanges
using .Exchanges.Instruments
using .Instruments.Derivatives
using PingPong.Engine: Engine, Strategies, Collections, Instances
using .Collections
using .Collections.TimeTicks
using .Instances
using PingPong.Data
using .Data.DFUtils
using Processing
using Misc

setexchange!(:kucoinfutures)
cfg = loadconfig!(nameof(exc.id); cfg=Config())
s = loadstrategy!(:MacdStrategy, cfg)
btc = s.universe[d"BTC/USDT:USDT"].instance[1]
fill!(s.universe, config.timeframes[(begin + 1):end]...)
