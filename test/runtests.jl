using Backtest
using Backtest.ExchangeTypes
using Aqua
using Test

@testset "Aqua" begin
    pkg = Backtest
    # Aqua.test_ambiguities(pkg) skip=true
    # Aqua.test_stale_deps(pkg; ignore=[:Aqua]) skip=true
    Aqua.test_unbound_args(pkg)
    Aqua.test_project_toml_formatting(pkg)
    Aqua.test_undefined_exports(pkg)
end

@testset "Exchanges" begin
    @test setexchange!(:kucoin).name == "KuCoin"
    @test begin
        getexchange!(:kucoin)
        :kucoin ∈ keys(ExchangeTypes.exchanges)
    end
end
# @test begin
# end
