using PingPong
using TimeTicks
using Instruments
using Instruments.Derivatives
using PingPong.Engine: Engine, Strategies as strat, Collections as co, Instances as ista
using Data: Data as da, DFUtils as dfu
using Processing: Processing as pro
using Misc: Misc as mi

const istr = Instruments
const der = Derivatives

setexchange!(:kucoinfutures)
cfg = loadconfig!(nameof(exc.id); cfg=Config())
s = loadstrategy!(:Example, cfg)
btc = s.universe[d"BTC/USDT:USDT"].instance[1]
fill!(s.universe, config.timeframes[(begin + 1):end]...)
