using Pkg

let lpath = joinpath(dirname(Pkg.project().path), "test")
    lpath ∉ LOAD_PATH && push!(LOAD_PATH, lpath)
end

using Cli

Cli.fetch("BTC/USDT"; exchanges="kucoin")
Cli.fetch("BTC/USDT", "ETH/USDT"; exchanges="kucoin")
