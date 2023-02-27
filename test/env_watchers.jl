using PingPong
using Instruments.Derivatives
using PingPong.Watchers
using PingPong.Data
using TimeTicks
const da = Data
const cg = PingPong.Watchers.CoinGecko
const cp = PingPong.Watchers.CoinPaprika
const excs = collect(keys(cg.loadderivatives!()))
const wc = PingPong.Watchers
const wi = PingPong.Watchers.WatchersImpls
const pro = wi.Processing
setexchange!(:bybit)
macro usdt_str(sym)
    s = uppercase(sym) * "/USDT:USDT"
    :($s)
end
usdm(sym) = "$(uppercase(sym))/USDT:USDT"
