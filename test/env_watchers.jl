using PingPong
using Instruments.Derivatives
using PingPong.Watchers
using PingPong.Data
using TimeTicks
cg = PingPong.Watchers.CoinGecko
excs = collect(keys(cg.loadderivatives!()))
wi = PingPong.Watchers.WatchersImpls
