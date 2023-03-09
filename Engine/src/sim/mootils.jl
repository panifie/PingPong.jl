module Mootils
using IterTools
using StatsBase
import Base.|>
|>(xs::Tuple{Float64,Float64}, f) = f(xs...)
|>(xs::Tuple{Float64,Float64,Float64}, f) = f(xs...)

export @swapnan, @swapinf
export filsoc, @fltinf, @filtnan
export @newarr, @arrfloat
export @unit_range!, unit_range
export @skipnan, @passnan

macro newarr(dims, type=Float64)
    quote
        Array{$(esc(type))}(undef, $(esc(dims)))
    end
end

macro enable(cond, body...)
    if cond
        quote
            $body...
        end
    else
        nothing
    end
end

macro passinf(arr, val=1.0)
    s_arr = esc(arr)
    s_val = esc(val)
    quote
        imap((el) -> isfinite(el) ? el : $s_val, $s_arr)
    end
end

macro passnan(arr, val=0.0)
    s_val = esc(val)
    s_arr = esc(arr)
    quote
        imap((el) -> isnan(el) ? $s_val : el, $s_arr)
    end
end

macro arrfloat(arr, yes=true)
    quote
        arr = $(esc(arr))
        if $yes == true
            Array{Float64,ndims(arr)}(arr)
        else
            arr
        end
    end
end

macro numinf(val, infv=1.0, nanv=0.0)
    ev = esc(val)
    pi = esc(infv)
    ni = esc(nanv)
    quote
        if $ev === Inf
            $pi
        elseif $ev == -Inf
            $ni
        else
            $ev
        end
    end
end

macro swapinf(arr, conv=false, nanv=0, infv=1)
    nanv = esc(nanv)
    infv = esc(infv)
    arr = esc(arr)
    quote
        @arrfloat(
            map((el) -> isfinite(el) ? el : (isnan(el) ? $nanv : sign(el) * $infv), $arr),
            $conv
        )
    end
end

macro swapnan(arr, val)
    quote
        map((el) -> isnan(el) ? $(esc(val)) : el, $(esc(arr)))
    end
end

macro filtnan(arr)
    quote
        filter(!isnan, $(esc(arr)))
    end
end

macro skipnan(f, arr, dims=nothing)
    arr = esc(arr)
    if isnothing(dims)
        quote
            $f(filter(!isnan, $(esc(arr))))
        end
    else
        quote
            mapslices(x -> $f(filter(!isnan, x)), $(esc(arr)); dims=$dims)
        end
    end
end

macro fltinf(arr)
    quote
        filter(isfinite, $(esc(arr)))
    end
end

macro _maparr(f, arr, dims, pred=!isnan)
    if isnothing(dims)
        quote
            $f(filter($pred, $(esc(arr))))
        end
    else
        quote
            mapslices(x -> $f(filter($pred, x)), $(esc(arr)); dims=$dims)
        end
    end
end

function unit_range(arr)
    return StatsBase.transform(fit(UnitRangeTransform, arr), arr)
end

macro unit_range!(arr, yes=true)
    if yes == true
        quote
            arr = $(esc(arr))
            return StatsBase.transform!(fit(UnitRangeTransform, arr), arr)
        end
    end
end

function filsoc(arr, pct, match; inv::Bool=false, concat::Bool=true)
    """ Filter an array above (below) a value, sort and concat the result of
    another array of same input length at the equivalent sorted index
         """
    pct_mask = inv ? arr .< pct : arr .> pct
    sort_mask = sortperm(arr[pct_mask, :])
    values = arr[pct_mask, :][sort_mask, :]

    if concat && !isnothing(match)
        values = hcat(values, match[pct_mask, :][sort_mask, :])
    end
    return values
end

function unzip(a)
    return map(x -> getfield.(a, x), fieldnames(eltype(a)))
end

@doc "Returns a view of `v` with value shifted according to `n` taking the last `window` values only.
It only makes sense when `n` > 0"
function lagged(v, window; idx=lastindex(v), n=1)
    @assert n > 0
    @view v[max(begin, idx - window - n + 1):(idx - n)]
end

end
