using Revise

using JuBot: @in_repl

# import Pkg; Pkg.activate("test/")
# using BenchmarkTools

exc, zi = @in_repl()
Revise.revise(JuBot)

using Fetch
JuBot.fetch_ohlcv(Val(:ask), exc,"4h"; qc="USDT", zi, update=true)
