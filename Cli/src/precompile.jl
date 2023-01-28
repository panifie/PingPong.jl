begin
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    Base.precompile(
        Tuple{
            Core.kwftype(typeof(fetch)),
            NamedTuple{(:exchange,),Tuple{String}},
            typeof(fetch),
            String,
        },
    )   # time: 7.18946
end
