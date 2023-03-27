include("noprecomp.jl")
using Pkg: Pkg;
let dse = "~/.julia/environments/$(VERSION)/"
    if dse ∉ LOAD_PATH
        push!(LOAD_PATH, dse)
    end
end
using Documenter, DocStringExtensions

# Modules
using PingPong
project_path = dirname(Pkg.project().path)
function use(name, args...)
    path = joinpath(project_path, args...)
    try
    if endswith(args[end], ".jl")
        include(path)
        @eval using .$name
    else
        path ∉ LOAD_PATH && push!(LOAD_PATH, path)
        Pkg.instantiate()
        @eval using $name
    end
    catch
        Pkg.activate(path)
        Pkg.instantiate()
        @eval using $name
        Pkg.activate(".")
    end
end
use(:Prices, "Data", "src", "prices.jl")
use(:Fetch, "Fetch")
use(:Short, "Analysis", "Mark", "Short")
use(:Long, "Analysis", "Mark", "Long")
use(:MVP, "Analysis", "Mark", "MVP")
use(:Processing, "Processing")
use(:Instruments, "Instruments")
use(:Exchanges, "Exchanges")
use(:Plotting, "Plotting")
use(:Analysis, "Analysis")
use(:Engine, "Engine")
use(:Watchers, "Watchers")
use(:Pbar, "Pbar")
use(:Stats, "Stats")
using PingPong.Data.DataStructures
@eval using Base: Timer

function filter_strategy(t)
    try
        if startswith(string(nameof(t)), "Strategy")
            false
        else
            true
        end
    catch
        false
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
