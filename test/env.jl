using JuBot: JuBot, Exchanges.Pairs
using .Pairs
using JuBot.Engine: Engine, Strategies, Collections
using .Collections: TimeTicks
using .TimeTicks
using JuBot.Data: Data, DFUtils

setexchange!(:kucoin)
cfg = loadconfig!(exc.sym.sym)
s = loadstrategy!(:MacdStrategy, cfg)
