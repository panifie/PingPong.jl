using DataFrames: DataFrame

ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

precompile(@in_repl, ())
precompile(JuBot.Data.load_pair, (AbstractString,))
precompile(JuBot.Data.load_pair, (ZarrInstance, AbstractString, String, String))
precompile(JuBot.Plotting.plotgrid, (DataFrame, Int, AbstractVector{String}))

precompile(Tuple{typeof(JuBot.Analysis.__init__)})
precompile(Tuple{typeof(JuBot.Data.__init__)})
precompile(Tuple{typeof(JuBot.Misc.Pbar.__init__)})
