using Revise

using PingPong: @in_repl

# import Pkg; Pkg.activate("test/")
# using BenchmarkTools

exc, zi = @in_repl()
Revise.revise(PingPong)

using Fetch
PingPong.fetch_ohlcv(Val(:ask), exc,"4h"; qc="USDT", zi, update=true)
