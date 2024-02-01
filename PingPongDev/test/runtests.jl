# All the packages added in the test/Project.toml go here (before the NO_TMP switch)
using Aqua
using Test
# Disable TMP project path
NO_TMP = "JULIA_NO_TMP" ∈ keys(ENV)
if NO_TMP
    using Pkg: Pkg
    # activate main project
    root = "."
    if isnothing(Pkg.project().name) && ispath(joinpath(dirname(pwd()), "Project.toml"))
        root = ".."
    end
    Pkg.activate(root)
    @assert Pkg.project().name == "PingPongDev"
    if ispath(joinpath(root, ".CondaPkg", "env"))
        ENV["JULIA_CONDAPKG_OFFLINE"] = "yes"
    end
end
# Skip heavy precomp during tests
ENV["JULIA_PRECOMP"] = ""
using PingPongDev
using PingPongDev.PingPong.Engine.Instances.Exchanges.Python.PythonCall.GC: enable as gc_enable, disable as gc_disable
PROJECT_PATH = pathof(PingPongDev) |> dirname |> dirname
push!(LOAD_PATH, dirname(PROJECT_PATH))
TEST_ALL = "all" ∈ ARGS || length(ARGS) == 0
FAILFAST = true # parse(Bool, get(ENV, "FAILFAST", "0"))

include("test_aqua.jl")
include("test_time.jl")
include("test_data.jl")
include("test_derivatives.jl")
include("test_markets.jl")
include("test_funding.jl")
include("test_exchanges.jl")
include("test_ohlcv.jl")
include("test_collections.jl")
include("test_orders.jl")
include("test_strategies.jl")

include("test_watchers.jl")
include("test_coinmarketcap.jl")
include("test_coingecko.jl")
include("test_coinpaprika.jl")

include("test_roi.jl")
include("test_profits.jl")
include("test_stoploss.jl")
include("test_tradesohlcv.jl")
include("test_backtest.jl")
include("test_paper.jl")
include("test_live.jl")
include("test_live_pong.jl")

test_map = [
    :aqua => [test_aqua],
    :time => [test_time],
    :data => [test_data],
    #
    :derivatives => [test_derivatives],
    :exchanges => [test_exchanges],
    :markets => [test_markets],
    :collections => [test_assetcollection],
    :orders => [test_orders],
    :strategies => [test_strategies],
    #
    :ohlcv => [test_ohlcv],
    :tradesohlcv => [test_tradesohlcv],
    :watchers => [test_watchers],
    #
    :profits => [test_profits],
    :roi => [test_roi],
    :stoploss => [test_stoploss],
    #
    :cmc => [test_cmc],
    :paprika => [test_paprika],
    :gecko => [test_coingecko],
    :funding => [test_funding],
    #
    :backtest => [test_backtest],
    :paper => [test_paper],
    :live => [test_live],
    :live_pong => [() -> test_live_pong(sync=true)],
]
for (testname, tests) in test_map
    if TEST_ALL || lowercase(string(testname)) ∈ ARGS
        for f in tests
            try
                gc_disable()
                f()
            finally
                gc_enable()
            end
        end
    end
end
