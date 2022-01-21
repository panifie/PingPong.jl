using Pkg

let lpath = joinpath(dirname(Pkg.project().path), "test")
    lpath ∉ LOAD_PATH && push!(LOAD_PATH, lpath)
end

using Backtest

Backtest.setexchange!(:kucoin)
Backtest.fetch_pairs("1h", ["BTC/USDT", "ETH/USDT"]; update=true)
Backtest.fetch_pairs("1d", "BTC/USDT")
