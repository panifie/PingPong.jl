# All the packages added in the test/Project.toml go here (before the NO_TMP switch)
using Aqua
using Test

include("env.jl")

all_tests = [
    :aqua,
    :time,
    :data,
    #
    :derivatives,
    :exchanges,
    :markets,
    :collections,
    :orders,
    :orders2,
    :positions,
    :instances,
    :strategies,
    #
    :ohlcv,
    :tradesohlcv,
    :watchers,
    #
    :profits,
    :roi,
    :stoploss,
    #
    :coinmarketcap,
    :coinpaprika,
    :coingecko,
    :funding,
    #
    :backtest,
    :paper,
    :live,
    :live_pong,
]

tests(selected=ARGS) = begin
    selected = string.(selected)
    test_all = "all" ∈ selected || length(selected) == 0
    for testname in all_tests
        if test_all || lowercase(string(testname)) ∈ selected
            name = Symbol(:test_, testname)
            file_name = joinpath(PROJECT_PATH, "test", string(name, ".jl"))
            if file_name ∉ _INCLUDED_TEST_FILES
                push!(_INCLUDED_TEST_FILES, file_name)
                (isdefined(Main, :Revise) ? includet : include)(file_name)
            end
            getproperty(@__MODULE__, name) |> invokelatest
        end
    end
end

if !isinteractive()
    tests()
end
