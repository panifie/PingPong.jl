# All the packages added in the test/Project.toml go here (before the NO_TMP switch)
using Aqua
using Test

include("env.jl")

test_map = [
    :aqua => [:test_aqua],
    :time => [:test_time],
    :data => [:test_data],
    #
    :derivatives => [:test_derivatives],
    :exchanges => [:test_exchanges],
    :markets => [:test_markets],
    :collections => [:test_assetcollection],
    :orders => [:test_orders],
    :strategies => [:test_strategies],
    #
    :ohlcv => [:test_ohlcv],
    :tradesohlcv => [:test_tradesohlcv],
    :watchers => [:test_watchers],
    #
    :profits => [:test_profits],
    :roi => [:test_roi],
    :stoploss => [:test_stoploss],
    #
    :cmc => [:test_cmc],
    :paprika => [:test_paprika],
    :gecko => [:test_coingecko],
    :funding => [:test_funding],
    #
    :backtest => [:test_backtest],
    :paper => [:test_paper],
    :live => [:test_live],
    :live_pong => [:test_live_pong],
]

tests(selected=ARGS) = begin
    test_all = "all" ∈ selected || length(selected) == 0
    for (testname, tests) in test_map
        if test_all || lowercase(string(testname)) ∈ selected
            for f in tests
                try
                    file_name = joinpath(PROJECT_PATH, "test", string("test_", testname, ".jl"))
                    if file_name ∉ _INCLUDED_TEST_FILES
                        push!(_INCLUDED_TEST_FILES, file_name)
                        (isdefined(Main, :Revise) ? includet : include)(file_name)
                    end
                    gc_disable()
                    getproperty(@__MODULE__, f) |> invokelatest
                finally
                    gc_enable()
                end
            end
        end
    end
end

if !isinteractive()
    tests()
end
