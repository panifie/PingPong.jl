using Pkg

let lpath = joinpath(dirname(Pkg.project().path), "test")
    lpath ∉ LOAD_PATH && push!(LOAD_PATH, lpath)
end

using PingPong
using PingPong.Exchanges: fetch!

fetch!() # load fetch_ohlcv func
PingPong.setexchange!(:kucoin)
PingPong.load_ohlcv("15m")
# User.fetch_ohlcv("1h", ["BTC/USDT", "ETH/USDT"]; update=true)
# User.fetch_ohlcv("1d", "BTC/USDT")
