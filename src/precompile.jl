using DataFrames: DataFrame

ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

precompile(@in_repl, ())
precompile(PingPong.Data.load, (AbstractString,))
precompile(PingPong.Data.load, (ZarrInstance, AbstractString, String, String))
precompile(PingPong.Plotting.plotgrid, (DataFrame, Int, AbstractVector{String}))

precompile(Tuple{typeof(PingPong.Analysis.__init__)})
precompile(Tuple{typeof(PingPong.Data.__init__)})
precompile(Tuple{typeof(PingPong.Misc.Pbar.__init__)})
