using Backtest
using Backtest.Engine
using Backtest.Engine: Strategies

setexchange!(:kucoin)
cfg = loadconfig!(exc.sym.sym)
s = loadstrategy!(:MacdStrategy, cfg)
