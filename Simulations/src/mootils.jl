@doc """
    Mootils

The Mootils module is a collection of tools, macros, and helper functions designed for work in scientific computations and statistical analysis.

It provides to manipulate and operate numerical arrays and introduces functionalities such as:

* Handling of special floating point values such as `NaN` and `Inf`. 
  Functions for replacing these values or filtering them out are provided by macros such as @swapnan, @swapinf, @filtnan, @fltinf.

* Creation of arrays with a specific type and shape using the @newarr macro.

* Conditional execution of a code block with the @enable macro.

* Traversal of arrays replacing non-finite values (@passinf, @passnan macros).

* Conversion of an array to one of type Float64 (@arrfloat macro).

* Transforming infinite values to specific numbers (@numinf macro).

* Filtering and sorting functions are included for arrays (@filsoc function).

* Functions for creating lagged views of arrays (lagged function).

Furthermore, this module enhances the |> operator to handle tuples as argument sequences and adds utilities for functional programming with arrays.

The module uses the StatsBase and IterTools packages.
"""
module Mootils
using IterTools
using StatsBase
using ..DocStringExtensions
import Base.|>
|>(xs::Tuple{Float64,Float64}, f) = f(xs...)
|>(xs::Tuple{Float64,Float64,Float64}, f) = f(xs...)

export @swapnan, @swapinf
export filsoc, @fltinf, @filtnan
export @newarr, @arrfloat
export @unit_range!, unit_range
export @skipnan, @passnan

@doc """
Create a new array with specified dimensions and element type.

$(TYPEDSIGNATURES)

This macro creates a new array with the given dimensions and element type. The array is initialized with undefined values.

"""
macro newarr(dims, type=Float64)
    quote
        Array{$(esc(type))}(undef, $(esc(dims)))
    end
end

@doc """Defines a macro that conditionally enables a block of code.

$(TYPEDSIGNATURES)

If the condition `cond` is true, the macro evaluates `body...`, otherwise it does nothing.

"""
macro enable(cond, body...)
    if cond
        quote
            $body...
        end
    else
        nothing
    end
end


@doc """ Replaces infinite values in an array with a specified value.

$(TYPEDSIGNATURES)

The `passinf` macro traverses an array and replaces any infinite values it encounters with a specified value.
The default replacement value is 1.0.
It uses the `imap` function from the IterTools package to achieve this.
"""
macro passinf(arr, val=1.0)
    s_arr = esc(arr)
    s_val = esc(val)
    quote
        imap((el) -> isfinite(el) ? el : $s_val, $s_arr)
    end
end

@doc """Defines a macro that replaces NaN values in an array with a specified value.

$(TYPEDSIGNATURES)

If the element `el` in the array `arr` is NaN, it is replaced with the value `val`. The default value is 0.0.

"""
macro passnan(arr, val=0.0)
    s_val = esc(val)
    s_arr = esc(arr)
    quote
        imap((el) -> isnan(el) ? $s_val : el, $s_arr)
    end
end

@doc """ Converts an array to Float64 type conditionally

$(TYPEDSIGNATURES)

The `arrfloat` macro takes an array and a boolean flag as input.
If the flag is `true`, it converts the array to Float64 type.
Otherwise, it returns the original array.

"""
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

@doc """ Transforms infinite values to specific numbers

$(TYPEDSIGNATURES)

The `numinf` macro takes a value and two optional parameters for infinite and negative infinite values.
If the input value is `Inf`, it is replaced with the first optional parameter (default is 1.0).
If the input value is `-Inf`, it is replaced with the second optional parameter (default is 0.0).
Otherwise, the original value is returned.

"""
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

@doc """ Replaces infinite and NaN values in an array with specified values

$(TYPEDSIGNATURES)

The `swapinf` macro takes an array and three optional parameters: a boolean flag and two values for NaN and infinite values.
It traverses the array and replaces any non-finite values it encounters with the specified values.
If the boolean flag is `true`, it also converts the array to Float64 type.

"""
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

@doc """ Replaces NaN values in an array with a specified value

$(TYPEDSIGNATURES)

The `swapnan` macro takes an array and a value as input.
It traverses the array and replaces any NaN values it encounters with the specified value.

"""
macro swapnan(arr, val)
    quote
        map((el) -> isnan(el) ? $(esc(val)) : el, $(esc(arr)))
    end
end

@doc """ Filters out NaN values from an array

$(TYPEDSIGNATURES)

The `filtnan` macro takes an array as input.
It filters out any NaN values it encounters in the array and returns the filtered array.

"""
macro filtnan(arr)
    quote
        filter(!isnan, $(esc(arr)))
    end
end

@doc """ Applies a function to an array, skipping NaN values

$(TYPEDSIGNATURES)

The `skipnan` macro takes a function, an array, and an optional dimension as input.
It applies the function to the array, skipping any NaN values.
If a dimension is specified, the function is applied to slices of the array along that dimension.

"""
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

@doc """ Filters out infinite values from an array

$(TYPEDSIGNATURES)

The `fltinf` macro takes an array as input.
It filters out any infinite values it encounters in the array and returns the filtered array.

"""
macro fltinf(arr)
    quote
        filter(isfinite, $(esc(arr)))
    end
end

@doc """ Applies a function to an array, skipping values based on a predicate

$(TYPEDSIGNATURES)

The `_maparr` macro takes a function, an array, a dimension, and a predicate as input.
It applies the function to the array, skipping any values that do not satisfy the predicate.
If a dimension is specified, the function is applied to slices of the array along that dimension.

"""
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

@doc """ Transforms an array to a unit range.

$(TYPEDSIGNATURES)

The `unit_range` function takes an array as input and transforms it to a unit range using the `UnitRangeTransform` from the `StatsBase` package.
The transformation is applied to the array and the transformed array is returned.

"""
function unit_range(arr)
    return StatsBase.transform(fit(UnitRangeTransform, arr), arr)
end

@doc """ Transforms an array to a unit range in-place.

$(TYPEDSIGNATURES)

The `unit_range!` function takes an array and a boolean flag as input. If the flag is `true`, it transforms the array to a unit range using the `UnitRangeTransform` from the `StatsBase` package. The transformation is applied in-place to the array.

"""
macro unit_range!(arr, yes=true)
    if yes == true
        quote
            arr = $(esc(arr))
            return StatsBase.transform!(fit(UnitRangeTransform, arr), arr)
        end
    end
end

@doc """ Filters, sorts, and optionally concatenates an array based on a value.

$(TYPEDSIGNATURES)

The `filsoc` function takes an array, a value, another array to match, and two optional boolean flags. It filters the input array based on the provided value, sorts it, and if the `concat` flag is `true`, concatenates the result with the matched array at the equivalent sorted index.

"""
function filsoc(arr, pct, match; inv::Bool=false, concat::Bool=true)
    pct_mask = inv ? arr .< pct : arr .> pct
    sort_mask = sortperm(arr[pct_mask, :])
    values = arr[pct_mask, :][sort_mask, :]

    if concat && !isnothing(match)
        values = hcat(values, match[pct_mask, :][sort_mask, :])
    end
    return values
end

@doc """ Unzips a collection of tuples into separate arrays.

$(TYPEDSIGNATURES)

The `unzip` function takes a collection of tuples as input. It separates each tuple into its constituent elements and returns a tuple of arrays, each containing the elements of the input tuples at the corresponding position.

"""
function unzip(a)
    return map(x -> getfield.(a, x), fieldnames(eltype(a)))
end

@doc """ Returns a view of `v` with value shifted according to `n` taking the last `window` values only.

$(TYPEDSIGNATURES)

The `lagged` function takes an array, a window size, an optional index, and a shift value `n` as input. It returns a view of the array with values shifted according to `n`, considering only the last `window` values. It only makes sense when `n` > 0.

"""
function lagged(v, window; idx=lastindex(v), n=1)
    @assert n > 0
    @view v[max(begin, idx - window - n + 1):(idx - n)]
end

end
