using Base: precompile
using DataFrames: DataFrame

precompile(@in_repl, ())
precompile(Backtest.Data.load_pair, (ZarrInstance, AbstractString, String, String))
precompile(Backtest.Plotting.plotgrid, (DataFrame, Int, AbstractVector{String}))
