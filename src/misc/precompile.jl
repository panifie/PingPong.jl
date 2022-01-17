using DataFrames: DataFrame

ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

precompile(@in_repl, ())
precompile(Backtest.Data.load_pair, (AbstractString,))
precompile(Backtest.Data.load_pair, (ZarrInstance, AbstractString, String, String))
precompile(Backtest.Plotting.plotgrid, (DataFrame, Int, AbstractVector{String}))

precompile(Tuple{typeof(Backtest.Analysis.__init__)})
precompile(Tuple{typeof(Backtest.Data.__init__)})
precompile(Tuple{typeof(Backtest.Misc.Pbar.__init__)})
