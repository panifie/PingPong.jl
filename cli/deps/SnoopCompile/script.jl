using Pkg

let lpath = joinpath(dirname(Pkg.project().path), "test")
    lpath ∉ LOAD_PATH && push!(LOAD_PATH, lpath)
end

using BacktestCLI

BacktestCLI.fetch("BTC/USDT"; exchange="kucoin")
BacktestCLI.fetch("BTC/USDT", "ETH/USDT"; exchange="kucoin")
