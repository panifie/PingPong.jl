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
    @assert Pkg.project().name == "JuBot"
    if ispath(joinpath(root, ".CondaPkg", "env"))
        ENV["JULIA_CONDAPKG_OFFLINE"] = "yes"
    end
end
using JuBot
using JuBot.ExchangeTypes
all = "all" ∈ ARGS || length(ARGS) == 0

test_aqua() = @testset "aqua" begin
    pkg = JuBot
    # Aqua.test_ambiguities(pkg) skip=true
    # Aqua.test_stale_deps(pkg; ignore=[:Aqua]) skip=true
    Aqua.test_unbound_args(pkg)
    Aqua.test_project_toml_formatting(pkg)
    Aqua.test_undefined_exports(pkg)
end

include("test_exchanges.jl")
include("test_collections.jl")

test_strategy() = @testset "strategy" begin
    @test begin
        @eval using JuBot.Engine
        cfg::Config = loadconfig!(Symbol(exc.id); cfg=Config())
        s = loadstrategy!(:MacdStrategy, cfg)
        [k.raw for k in s.universe.data.asset] == ["ETH/USDT", "BTC/USDT", "XMR/USDT"]
    end
end
test_backtest() = @testset "backtest" begin
end
include("test_derivatives.jl")
include("test_time.jl")
include("test_ohlcv.jl")
include("test_orders.jl")
test_map = Dict(
    :aqua => [test_aqua],
    :exchanges => [test_exchanges],
    :assets => [test_exch, test_assetcollection],
    :strategy => [test_exch, test_strategy],
    :backtest => [test_exch, test_backtest],
    :derivatives => [test_derivatives],
    :time => [test_time],
    :ohlcv => [test_ohlcv],
    :orders => [test_orders]
)
for (testname, tests) in test_map
    if all || lowercase(string(testname)) ∈ ARGS
        for f in tests
            f()
        end
    end
end
