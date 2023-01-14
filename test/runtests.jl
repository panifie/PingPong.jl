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

test_aqua() = @testset "Aqua" begin
    pkg = JuBot
    # Aqua.test_ambiguities(pkg) skip=true
    # Aqua.test_stale_deps(pkg; ignore=[:Aqua]) skip=true
    Aqua.test_unbound_args(pkg)
    Aqua.test_project_toml_formatting(pkg)
    Aqua.test_undefined_exports(pkg)
end

test_exch() = @test setexchange!(:kucoin).name == "KuCoin"

test_exchanges() = @testset "Exchanges" begin
    test_exch()
    @test begin
        getexchange!(:kucoin)
        :kucoin ∈ keys(ExchangeTypes.exchanges)
    end
    @test begin
        @eval begin
            using JuBot.Exchanges: get_pairs
            const getpairs = JuBot.Exchanges.get_pairs
            prs = getpairs()
        end
        length(prs) > 0
    end
end

include("test_collections.jl")

test_strategy() = @testset "Strategy" begin
    @test begin
        @eval using JuBot.Engine
        cfg::Config = loadconfig!(Symbol(exc.id); cfg=Config())
        s = loadstrategy!(:MacdStrategy, cfg)
        [k.raw for k in s.universe.data.asset] == ["ETH/USDT", "BTC/USDT", "XMR/USDT"]
    end
end
test_backtest() = @testset "JuBot" begin
end
test_map = Dict(
    :aqua => [test_aqua],
    :exchanges => [test_exchanges],
    :assets => [test_exch, test_assetcollection],
    :strategy => [test_exch, test_strategy],
    :backtest => [test_exch, test_backtest]
)
for (testname, tests) in test_map
    if all || lowercase(string(testname)) ∈ ARGS
        for f in tests
            f()
        end
    end
end
