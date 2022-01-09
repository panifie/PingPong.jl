using Base: precompile

precompile(@in_repl, ())
precompile(load_pair, (ZarrInstance, AbstractString, String, String))
precompile(plotgrid, (DataFrame, Int, AbstractVector{String}))
