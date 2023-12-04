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
    @assert Pkg.project().name == "PingPong"
    if ispath(joinpath(root, ".CondaPkg", "env"))
        ENV["JULIA_CONDAPKG_OFFLINE"] = "yes"
    end
end
using PingPong
TEST_ALL = "all" ∈ ARGS || length(ARGS) == 0

include("test_aqua.jl")
include("test_time.jl")
include("test_data.jl")
include("test_derivatives.jl")
include("test_markets.jl")
include("test_exchanges.jl")
# include("test_ohlcv.jl")
# include("test_collections.jl")
# include("test_orders.jl")
# include("test_strategies.jl")

# include("test_watchers.jl")
# include("test_coinmarketcap.jl")
# include("test_coingecko.jl")
# include("test_coinpaprika.jl")

# include("test_tradesohlcv.jl")

test_map = Dict(
    :aqua => [test_aqua],
    :data => [test_data],
    # :exchanges => [test_exchanges],
    # :assets => [test_exch, test_assetcollection],
    # :collections => [test_collections],
    # :strategy => [test_exch, test_strategy],
    # :backtest => [test_exch, test_backtest],
    # :derivatives => [test_derivatives],
    :time => [test_time],
    # :ohlcv => [test_ohlcv],
    # :orders => [test_orders],
    # :cmc => [test_coinmarketcap],
    # :gecko => [test_coingecko],
    # :paprika => [test_coinpaprika],
    # :tradesohlcv => [test_tradesohlcv]
)
for (testname, tests) in test_map
    if TEST_ALL || lowercase(string(testname)) ∈ ARGS
        for f in tests
            f()
        end
    end
end
