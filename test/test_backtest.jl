using JuBot
using JuBot.Engine
using JuBot.Engine: Strategies

setexchange!(:kucoin)
cfg = loadconfig!(exc.sym.sym)
s = loadstrategy!(:MacdStrategy, cfg)
