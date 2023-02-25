using PingPong
using Instruments.Derivatives
using PingPong.Watchers
using PingPong.Data
using TimeTicks
da = Data
cg = PingPong.Watchers.CoinGecko
cp = PingPong.Watchers.CoinPaprika
excs = collect(keys(cg.loadderivatives!()))
wc = PingPong.Watchers
wi = PingPong.Watchers.WatchersImpls
pro = wi.Processing
setexchange!(:bybit)
macro usdt_str(sym)
    s = uppercase(sym) * "/USDT:USDT"
    :($s)
end
usdm(sym) = "$(uppercase(sym))/USDT:USDT"
