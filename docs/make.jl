include("noprecomp.jl")
using Pkg: Pkg;
Pkg.activate("PingPong")
let dse = "~/.julia/environments/$(VERSION)/"
    if dse ∉ LOAD_PATH
        push!(LOAD_PATH, dse)
    end
end
using Documenter, DocStringExtensions, Suppressor

# Modules
using PingPong
project_path = dirname(dirname(Pkg.project().path))
function use(name, args...; activate=false)
    activate_and_import() = begin
        prev = Pkg.project().path
        try
            Pkg.activate(path)
            Pkg.instantiate()
            @eval using $name
        catch
        end
        Pkg.activate(prev)
    end

    path = joinpath(project_path, args...)
    @suppress if activate
        activate_and_import()
    else
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
            activate_and_import()
        end
    end
end
get(ENV, "LOADED", "false") == "true" || begin
    use(:Prices, "Data", "src", "prices.jl")
    use(:Fetch, "Fetch")
    use(:Processing, "Processing")
    use(:Instruments, "Instruments")
    use(:Exchanges, "Exchanges")
    use(:Plotting, "Plotting")
    use(:Analysis, "Analysis", activate=true)
    use(:Engine, "Engine")
    use(:Watchers, "Watchers")
    use(:Pbar, "Pbar")
    use(:Stats, "Stats")
    use(:Optimization, "Optimization")
    use(:Ccxt, "Ccxt")
    use(:Python, "Python")
    using PingPong.Data.DataStructures
    @eval using Base: Timer
    ENV["LOADED"] = "true"
end

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
        "Introduction" => ["index.md"],
        "Types" => "types.md",
        "Strategies" => "strategy.md",
        "Engine" => [
            "Executors" => "engine/engine.md",
            "Backtesting" => "engine/backtesting.md",
            "Paper" => "engine/paper.md",
            "Live" => "engine/live.md",
            "Features" => "engine/features.md",
        ],
        "Exchanges" => "exchanges.md",
        "Data" => "data.md",
        "Watchers" => [
            "Interface" => "watchers/watchers.md",
            "Apis" => [
                "watchers/apis/coingecko.md",
                "watchers/apis/coinpaprika.md",
                "watchers/apis/coinmarketcap.md",
            ],
        ],
        "Stats" => "stats.md",
        "Optimization" => "optimization.md",
        "Plotting" => "plotting.md",
        "Misc" => [
            "Config" => "config.md",
            "Disambiguation" => "disambiguation.md",
            "Troubleshooting" => "troubleshooting.md",
            "Devdocs" => "devdocs.md",
            "Contacts" => "contacts.md",
        ],
        "Customizations" => [
            "Overview" => "customizations/customizations.md",
            "Orders" => "customizations/orders.md",
            "Backtester" => "customizations/backtest.md",
            "Exchanges" => "customizations/exchanges.md",
        ],
        "API" => [
            "API/collections.md",
            "API/data.md",
            "API/ccxt.md",
            "API/dfutils.md",
            "API/executors.md",
            "API/exchanges.md",
            "API/fetch.md",
            "API/engine.md",
            "API/instances.md",
            "API/instruments.md",
            "API/misc.md",
            "API/optimization.md",
            "API/pbar.md",
            "API/plotting.md",
            "API/prices.md",
            "API/processing.md",
            "API/python.md",
            "API/stats.md",
            "API/strategies.md",
            "Analysis" => ["API/analysis/analysis.md"],
        ],
    ],
    format=Documenter.HTML(; sidebar_sitename=false),
)
