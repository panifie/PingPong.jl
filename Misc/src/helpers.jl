function queryfromstruct(T::Type, sep=","; kwargs...)
    query = try
        T(; kwargs...)
    catch error
        error isa ArgumentError && @error "Wrong query parameters for ($(st))."
        rethrow(error)
    end
    params = Dict()
    for s in fieldnames(T)
        f = getproperty(query, s)
        isnothing(f) && continue
        ft = typeof(f)
        hasmethod(length, (ft,)) && length(f) == 0 && continue
        params[string(s)] =
            ft != String && hasmethod(iterate, (ft,)) ? join(f, sep) : string(f)
    end
    params
end

function isdirempty(path::T where {T})
    allpaths = collect(walkdir(path))
    length(allpaths) == 1 && isempty(allpaths[1][2]) && isempty(allpaths[1][3])
end

@doc "Returns the range index of sorted vector `v` for all the values after `d`.
when `strict` is false, the range will start after only the first occurence of `d`."
function rangeafter(v::AbstractVector, d; strict=true, kwargs...)
    r = searchsorted(v, d; kwargs...)
    from = if length(r) > 0
        ifelse(strict, r.start + length(r), r.start + 1)
    else
        r.start
    end
    from:lastindex(v)
end

@doc "Returns a view of the sorted vector `v`, indexed using `rangeafter`."
after(v::AbstractVector, d) = view(v, rangeafter(v, d))
