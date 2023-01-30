using PingPong
using PingPong.Watchers
cg = PingPong.Watchers.CoinGecko
excs = collect(keys(cg.loadderivatives!()))
