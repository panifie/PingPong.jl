using Lang: @preset, @precomp
using Reexport

@preset begin
    @precomp begin
        Dict{String,ZarrInstance}()
        Ref{Option{ZarrInstance}}()
    end
    const zi = Ref{Option{ZarrInstance}}()
    const zcache = Dict{String,ZarrInstance}()
    @precomp begin
        @eval @reexport using Zarr
        ZarrInstance()
        zilmdb()
        __init__()
    end
end
