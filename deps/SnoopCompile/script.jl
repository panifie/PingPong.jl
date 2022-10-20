using Pkg

let lpath = joinpath(dirname(Pkg.project().path), "test")
    lpath ∉ LOAD_PATH && push!(LOAD_PATH, lpath)
end

using Backtest.User
using Backtest.User.Exchanges: fetch!

fetch!() # load fetch_pairs func
User.setexchange!(:kucoin)
User.load_pairs("15m")
# User.fetch_pairs("1h", ["BTC/USDT", "ETH/USDT"]; update=true)
# User.fetch_pairs("1d", "BTC/USDT")
