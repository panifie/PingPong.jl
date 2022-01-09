using Revise
using Backtest
Revise.revise(Backtest)
# import Pkg; Pkg.activate("test/")
# using BenchmarkTools

exc, zi = Backtest.@in_repl()

Backtest.fetch_pairs(Val(:ask), exc,"4h"; qc="USDT", zi, update=true)
