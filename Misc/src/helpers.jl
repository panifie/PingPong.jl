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
when `strict` is false, the range will start after the first occurence of `d`."
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
after(v::AbstractVector, d; kwargs...) = view(v, rangeafter(v, d; kwargs...))

@doc "Returns the range index of sorted vector `v` for all the values before `d`.
when `strict` is false, the range will start before the last occurence of `d`."
function rangebefore(v::AbstractVector, d; strict=true, kwargs...)
    r = searchsorted(v, d; kwargs...)
    to = if length(r) > 0
        ifelse(strict, r.stop - length(r), r.stop - 1)
    else
        r.stop
    end
    firstindex(v):to
end

@doc "Returns a view of the sorted vector `v`, indexed using `rangebefore`."
before(v::AbstractVector, d; kwargs...) = view(v, rangebefore(v, d; kwargs...))

@doc "Returns the range index of sorted vector `v` for all the values before `d`.
Argument `strict` behaves same as `rangeafter` and `rangebefore`."
function rangebetween(v::AbstractVector, left, right; kwargs...)
    l = rangeafter(v, left; kwargs...)
    r = rangebefore(v, right; kwargs...)
    (l.start):(r.stop)
end

@doc "Returns a view of the sorted vector `v`, indexed using `rangebetween`.

```julia
julia> between([1, 2, 3, 3, 3], 3, 3; strict=true)
0-element view(::Vector{Int64}, 6:5) with eltype Int64
julia> between([1, 2, 3, 3, 3], 1, 3; strict=true)
1-element view(::Vector{Int64}, 2:2) with eltype Int64:
 2
julia> between([1, 2, 3, 3, 3], 2, 3; strict=false)
2-element view(::Vector{Int64}, 3:4) with eltype Int64:
 3
 3
```
"
function between(v::AbstractVector, left, right; kwargs...)
    view(v, rangebetween(v, left, right; kwargs...))
end

