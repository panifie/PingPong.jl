module Rolling
using MaxMinFilters: movmaxmin
using DataStructures: CircularDeque
using Iterators: take, drop
# using OnlineStats: MovingWindow, fit!
const ut = Mootils

export rolling_sum_1d, rolling_sum_1d!, rolling_prod_1d, rolling_func_1d, rolling_norm_1d

function _init_trail(arr, window; stable=true, nanv=0, infv=1)
    if typeof(arr) <: Base.Generator
        et = eltype(first(arr))
        els = take(arr, window)
    else
        et = eltype(arr)
        els = view(arr, 1:window)
    end
    trail = CircularDeque{et}(window + 1)
    @inbounds for el in els
        push!(trail, ut.@numinf(el, nanv, infv))
    end
    # trail = MovingWindow(window, et)
    # fit!(trail, @passinf(els, stable, nanv, infv))
    return trail
end

function rolling_sum_1d!(arr, window, default=NaN; out=nothing, stable=true)
    if isnothing(out)
        out = arr
    end
    return _rolling_sum_1d(arr, window, default; out=out, stable=stable)
end

function rolling_sum_1d(arr, window, default=NaN; stable=true)
    out = Array{typeof(first(arr))}(undef, length(arr))
    return _rolling_sum_1d(arr, window, default; out=out, stable=stable)
end

function _rolling_sum_1d(data, window, default=NaN; out, stable=true)
    """ Rolling sum over a generator """
    len = length(data)

    trail = _init_trail(data, window)
    # take the sum before setting out initial values
    # in case output and input array are the same
    rol = sum(take(ut.@passinf(data), window))
    out[1:(window - 1)] .= default
    out[window] = rol
    n = window + 1
    @inbounds for v in drop(data, window)
        v = ut.@numinf(v, 0, 0)
        push!(trail, v)
        rol = rol - popfirst!(trail) + v
        # rol = rol - trail[1] + v
        # fit!(trail, v)
        out[n] = rol
        n += 1
    end
    return out
end

function rolling_mean_1d(arr, window, default=NaN)
    return rolling_sum_1d(arr, window, default) ./ window
end

function rolling_mean_1d!(arr, window, default=NaN)
    rolling_sum_1d!(arr, window, default) ./ window
    arr[:] ./= window
end

function rolling_prod_1d(arr, window, default=NaN)
    len = length(arr)
    res = typeof(arr)(undef, len)
    acc = prod(view(arr, 1:window))
    res[1:window] .= default
    res[window] = acc
    for n in (window + 1):len
        acc = acc / arr[n - window] * arr[n]
        res[n] = acc
    end
    # the logsum/exp is 4x slower
    return res
end

function rolling_func_1d(arr, split, apply, combine=(x) -> x; window, acc=0, default=NaN)
    len = length(arr)
    res = typeof(arr)(undef, len)
    res[1:(window - 1)] .= default
    for n in 1:window
        acc = apply(acc, arr[n])
    end
    res[window] = combine(acc)
    @inbounds for n in (window + 1):len
        acc = apply(split(acc, arr[n - window]), arr[n])
        res[n] = combine(acc)
    end
    return res
end

function rolling_norm_1d!(arr, window, out=nothing, default=NaN)
    if isnothing(out)
        out = arr
    end
    _rolling_norm_1d(arr, window, out, default)
end

function rolling_norm_1d(arr, window, default=NaN)
    out = similar(arr)
    _rolling_norm_1d(arr, window, out, default)
end

|>(xs::Tuple{Array,Array}, f) = f(xs...)
function _rolling_norm_1d(arr, window, out, default)
    movmaxmin(arr, window) |> (mx, mn) -> begin
        out[:] = (arr .- mn) ./ (mx .- mn)
        out[1:(window - 1)] .= default
        out
    end
end

end

using ..Rolling: Rolling
