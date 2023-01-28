using Pkg: Pkg;
let dse = "~/.julia/environments/$(VERSION)/"
    if dse ∉ LOAD_PATH
        push!(LOAD_PATH, dse)
    end
end
using Documenter, DocStringExtensions

# Modules
using PingPong
using Pbar
project_path = dirname(Pkg.project().path)
function use(name, args...)
    path = joinpath(project_path, args...)
    if endswith(args[end], ".jl")
        include(path)
        @eval using .$name
    else
        path ∉ LOAD_PATH && push!(LOAD_PATH, path)
        @eval using $name
    end
end
use(:Prices, "Data", "src", "prices.jl")
use(:Fetch, "Exchanges", "Fetch")
use(:Short, "Analysis", "Mark", "Short")
use(:Long, "Analysis", "Mark", "Long")
use(:MVP, "Analysis", "Mark", "MVP")
use(:Processing, "Analysis", "Processing")
use(:Instruments, "Instruments")
use(:Exchanges, "Exchanges")
use(:Plotting, "Plotting")
use(:Analysis, "Analysis")
use(:Engine, "Engine")
use(:Watchers, "Watchers")
using DataStructures
@eval using Base: Timer

function filter_strategy(t)
    if startswith(string(nameof(t)), "Strategy")
        false
    else
        true
    end
end

makedocs(;
    sitename="PingPong.jl",
    pages=[
        "index.md",
        "types.md",
        "strategy.md",
        "engine/engine.md",
        "exchanges.md",
        "data.md",
        "processing.md",
        "Watchers" => [
            "watchers/watchers.md",
            "watchers/apis/coingecko.md",
            "watchers/apis/coinpaprika.md",
            "watchers/apis/coinmarketcap.md",
        ],
        "misc.md",
        "plotting.md",
        "analysis.md",
    ],
)
