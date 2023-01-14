using JuBot: JuBot, Exchanges.Pairs
using ExchangeTypes: exc
using .Pairs
using JuBot.Engine: Engine, Strategies, Collections, Instances
using .Collections: TimeTicks
using .Collections
using .TimeTicks
using JuBot.Data: Data, DFUtils
using Processing
using Misc: Config

setexchange!(:kucoin)
cfg = loadconfig!(nameof(exc.id); cfg=Config())
s = loadstrategy!(:MacdStrategy, cfg)
btc = s.universe[a"BTC/USDT"].instance[1]
fill!(s.universe, config.timeframes[begin+1:end]...)
