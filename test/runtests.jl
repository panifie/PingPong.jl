using Backtest
using Test
using Aqua

pkg = Backtest
# Aqua.test_ambiguities(pkg)
Aqua.test_stale_deps(pkg; ignore=[:Aqua])
Aqua.test_unbound_args(pkg)
Aqua.test_project_toml_formatting(pkg)
Aqua.test_undefined_exports(pkg)

@test setexchange!(:kucoin).name == "KuCoin"
@test begin
    getexchange!(:kucoin)
    :kucoin ∈ Backtest.Misc.exchanges
end
# @test begin
# end
