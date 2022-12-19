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
    @assert Pkg.project().name == "Backtest"
    if ispath(joinpath(root, ".CondaPkg", "env"))
        ENV["JULIA_CONDAPKG_OFFLINE"] = :yes
    end
end
using Backtest
using Backtest.ExchangeTypes
all = "all" ∈ ARGS || length(ARGS) == 0

test_aqua() = @testset "Aqua" begin
    pkg = Backtest
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
        @eval prs = get_pairs()
        length(prs) > 0
    end
end

# TODO: add some stub data
test_portfolio() = @testset "Portfolio" begin
    @test begin
        if !isdefined(@__MODULE__, :prs)
            @eval prs = get_pairs()
        end
        @eval pf = Portfolio(prs)
        size(pf.data)[1] == length(prs)
    end
    @test !isnothing(pf[q=:USDT])
    @test !isnothing(pf[b=:BTC])
    @test !isnothing(pf[e=:kucoin])
    @test !isnothing(pf[b=:BTC, q=:USDT])
    @test !isnothing(pf[b=:BTC, q=:USDT, e=:kucoin])
end

test_strategy() = @testset "Strategy" begin
    @test !isnothing(Strategy())
end
# @test begin end
#

test_map = Dict(
    :qqua => [test_aqua],
    :exchanges => [test_exchanges],
    :portfolio => [test_exch, test_portfolio],
    :strategy => [test_exch, test_strategy],
)
for (testname, tests) in test_map
    if all || lowercase(string(testname)) ∈ ARGS
        for f in tests
            f()
        end
    end
end
