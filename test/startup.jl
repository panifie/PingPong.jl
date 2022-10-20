using Revise

using Backtest: @in_repl

# import Pkg; Pkg.activate("test/")
# using BenchmarkTools

exc, zi = @in_repl()
Revise.revise(Backtest)

using Fetch
Backtest.fetch_pairs(Val(:ask), exc,"4h"; qc="USDT", zi, update=true)
