using Pkg

let lpath = joinpath(dirname(Pkg.project().path), "test")
    lpath ∉ LOAD_PATH && push!(LOAD_PATH, lpath)
end

using JuBot
using JuBot.Exchanges: fetch!

fetch!() # load fetch_pairs func
JuBot.setexchange!(:kucoin)
JuBot.load_pairs("15m")
# User.fetch_pairs("1h", ["BTC/USDT", "ETH/USDT"]; update=true)
# User.fetch_pairs("1d", "BTC/USDT")
