# countdecimals(num::Float64) = abs(Base.Ryu.reduce_shortest(num)[2])
# insert_and_dedup!(v::Vector, x) = (splice!(v, searchsorted(v,x), [x]); v)

@doc """Sets the offline mode.

$(TYPEDSIGNATURES)

This function sets the offline mode based on the `PINGPONG_OFFLINE` environment variable. If the environment variable is set, it parses its value as a boolean to set the offline mode.
It is used to skip some errors during precompilation, if precompiling offline.

"""
setoffline!() = begin
    opt = get(ENV, "PINGPONG_OFFLINE", "")
    OFFLINE[] = if opt == ""
        false
    else
        @something tryparse(Bool, opt) false
    end
end

isoffline() = OFFLINE[]

@doc """Same as the Lang.@ignore` macro, but only if `PINGPONG_OFFLINE` is set."""
macro skipoffline(
    expr,
    this_file=string(__source__.file),
    this_line=__source__.line,
    this_module=__module__,
)
    ex = if expr.head == :let
        let_vars = expr.args[1]
        # Main.e = let_vars
        quote
            let $(if let_vars.head == :(=)
                    (let_vars,)
                elseif isempty(let_vars.args)
                    ()
                else
                    let_vars.args
                end...)
                $(@__MODULE__).@skipoffline $(expr.args[2]) $this_file $this_line $this_module
            end
        end
    elseif expr.head == :block
        this_expr = :(
            begin end
        )
        args = this_expr.args
        n = 0
        for line in expr.args
            line isa LineNumberNode && continue
            push!(
                args,
                :($(@__MODULE__).@skipoffline(
                    $line, $this_file, $(this_line + n), $this_module
                )),
            )
            n += 1
        end
        this_expr
    else
        quote
            try
                $expr
            catch
                if $(isoffline)()
                    @error "skipping error since offline" maxlog = 1 _module = $this_module _file = $this_file _line = $this_line exception = (
                        first(Base.catch_stack())...,
                    )
                else
                    rethrow()
                end
            end
        end
    end
    esc(ex)
end

@doc """Finds the module corresponding to a given symbol.

$(TYPEDSIGNATURES)

This function takes a symbol `sym` and attempts to find the corresponding module in the loaded modules.

"""
function _find_module(sym)
    hasproperty(@__MODULE__, sym) && return getproperty(@__MODULE__, sym)
    hasproperty(Main, sym) && return getproperty(Main, sym)
    try
        return @eval (using $sym; $sym)
    catch
    end
    nothing
end

@doc """Creates a query from a struct type.

$(TYPEDSIGNATURES)

This function takes a struct type `T` and a separator `sep`, and creates a query string using the fields and their values in `T`.

"""
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

@doc """Checks if a directory is empty.

$(TYPEDSIGNATURES)

This function takes a `path` and returns `true` if the directory at the given path is empty, and `false` otherwise.

"""
function isdirempty(path::AbstractString)
    allpaths = collect(walkdir(path))
    length(allpaths) == 1 && isempty(allpaths[1][2]) && isempty(allpaths[1][3])
end

_def(::Vector{<:AbstractFloat}) = NaN
_def(::Vector) = missing
@doc """Shifts elements in a vector.

$(TYPEDSIGNATURES)

This function shifts the elements in `arr` by `n` positions to the left. The new elements added to the end of the array are set to the value of `def`.
"""
function shift!(arr::Vector{<:AbstractFloat}, n=1, def=_def(arr))
    circshift!(arr, n)
    if n >= 0
        arr[begin:n] .= def
    else
        arr[(end + n):end] .= def
    end
    arr
end

@doc """Finds the range after a specified value in a vector.

$(TYPEDSIGNATURES)

This function takes a vector `v` and a value `d`, and returns a range that starts after the first occurrence of `d` in `v`. If `strict` is true, the range starts after `d`, otherwise it starts at `d`.

"""
function rangeafter(v::AbstractVector, d; strict=true, kwargs...)
    r = searchsorted(v, d; kwargs...)
    from = if length(r) > 0
        ifelse(strict, r.start + length(r), r.start + 1)
    else
        r.start
    end
    from:lastindex(v)
end

@doc """Returns a view of the vector after a specified value.

$(TYPEDSIGNATURES)

This function returns a view of the vector `v` starting from the position after the first occurrence of `d`. The behavior can be adjusted using keyword arguments passed to `rangeafter`.

"""
after(v::AbstractVector, d; kwargs...) = view(v, rangeafter(v, d; kwargs...))

@doc "Complement of [`rangeafter`](@ref)."
function rangebefore(v::AbstractVector, d; strict=true, kwargs...)
    r = searchsorted(v, d; kwargs...)
    to = if length(r) > 0
        ifelse(strict, r.stop - length(r), r.stop - 1)
    else
        r.stop
    end
    firstindex(v):to
end

@doc "Complement of [`after`](@ref)."
before(v::AbstractVector, d; kwargs...) = view(v, rangebefore(v, d; kwargs...))

@doc """Finds the range between two specified values in a vector.

$(TYPEDSIGNATURES)

This function takes a vector `v` and two values `left` and `right`, and returns a range that starts from the position of `left` and ends at the position of `right` in `v`.

"""
function rangebetween(v::AbstractVector, left, right; kwargs...)
    l = rangeafter(v, left; kwargs...)
    r = rangebefore(v, right; kwargs...)
    (l.start):(r.stop)
end

@doc "Returns a view of the sorted vector `v`, indexed using `rangebetween`.

$(TYPEDSIGNATURES)

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

@doc """Rewrites keys in a dictionary based on a function.

$(TYPEDSIGNATURES)

This function takes a dictionary `dict` and a function `f`, and rewrites each key in the dictionary by applying the function `f` to it.

"""
function rewritekeys!(dict::AbstractDict, f)
    for (k, v) in dict
        delete!(dict, k)
        setindex!(dict, v, f(k))
    end
    dict
end

@doc """Swaps keys in a dictionary based on a function and new key type.

$(TYPEDSIGNATURES)

This function takes a dictionary `dict`, a function `f`, and a new key type `k_type`. It returns a new dictionary of type `dict_type` where each key is transformed by the function `f` and cast to `k_type`.

"""
function swapkeys(dict::AbstractDict{K,V}, k_type::Type, f; dict_type=Dict) where {K,V}
    out = dict_type{k_type,V}()
    for (k, v) in dict
        out[f(k)] = v
    end
    out
end

@doc """Checks if an iterable is strictly sorted.

$(TYPEDSIGNATURES)

This function takes an iterable `itr` and returns `true` if the elements in `itr` are strictly increasing, and `false` otherwise.

"""
function isstrictlysorted(itr...)
    y = iterate(itr)
    y === nothing && return true
    prev, state = y
    y = iterate(itr, state)
    while y !== nothing
        this, state = y
        prev < this || return false
        prev = this
        y = iterate(itr, state)
    end
    return true
end

# slow version but precise
# roundfloat(val, prec) = begin
#     inv_prec = 1.0 / prec
#     round(round(val * inv_prec) / inv_prec, digits=abs(Base.Ryu.reduce_shortest(prec)[2]))
# end

roundfloat(val, prec) = begin
    inv_prec = 1.0 / prec
    round(val * inv_prec) / inv_prec
end

toprecision(n::Integer, prec::Integer) = roundfloat(n, prec)
@doc "When precision is a float it represents the pip.

$(TYPEDSIGNATURES)
"
function toprecision(n::T where {T<:Union{Integer,AbstractFloat}}, prec::AbstractFloat)
    roundfloat(n, prec)
end
@doc "When precision is a Integer it represents the number of decimals.

$(TYPEDSIGNATURES)
"
function toprecision(n::AbstractFloat, prec::Int)
    round(n; digits=prec)
end

@doc """ Round a float to a given precision.

$(TYPEDSIGNATURES)

When the precision is a float it represents the number of pips.
When the precision is an integer it represents the number of decimals.

Examples:
"""
function toprecision(n::AbstractFloat, prec::UInt)
    round(n; digits=prec - 1)
end

@doc """Checks if a value is approximately zero.

$(TYPEDSIGNATURES)

This function takes a value `v` and a tolerance `atol`. It returns `true` if the absolute difference between `v` and zero is less than or equal to `atol`, and `false` otherwise.

"""
approxzero(v::T; atol=ATOL) where {T} = isapprox(v, zero(T); atol)
@doc """Checks if a value is greater than or approximately equal to zero.

$(TYPEDSIGNATURES)

This function takes a value `v` and a tolerance `atol`. It returns `true` if `v` is greater than zero or if the absolute difference between `v` and zero is less than or equal to `atol`, and `false` otherwise.

"""
gtxzero(v::T; atol=ATOL) where {T} = v > zero(T) || isapprox(v, zero(T); atol)
ltxzero(v::T; atol=ATOL) where {T} = v < zero(T) || isapprox(v, zero(T); atol)
@doc "Alias to `abs`"
positive(v) = abs(v)
@doc "`negate(abs(v))`"
negative(v) = Base.negate(abs(v))
@doc "Increment an integer reference by one"
inc!(v::Ref{I}) where {I<:Integer} = v[] += one(I)
@doc "Decrement an integer reference by one"
dec!(v::Ref{I}) where {I<:Integer} = v[] -= one(I)
@doc "Get the `attrs` field of the input object."
attrs(d) = getfield(d, :attrs)
@doc "Get all `keys...` from the `attrs` field of the input object.

$(TYPEDSIGNATURES)
"
attrs(d, keys...) =
    let a = attrs(d)
        (a[k] for k in keys)
    end
@doc "Get `k` from the `attrs` field of the input object.

$(TYPEDSIGNATURES)
"
attr(d, k) = attrs(d)[k]
@doc "Get `k` from the `attrs` field of the input object, or `v` if `k` is not present.

$(TYPEDSIGNATURES)
"
attr(d, k, v) = get(attrs(d), k, v)
@doc "Get `k` from the `attrs` field of the input object, or `v` if `k` is not present, setting `k` to `v`.

$(TYPEDSIGNATURES)
"
attr!(d, k, v) = get!(attrs(d), k, v)
@doc "Set `k` in the `attrs` field of the input object to `v`.

$(TYPEDSIGNATURES)
"
modifyattr!(d, v, op, keys...) =
    let a = attrs(d)
        for k in keys
            a[k] = op(a[k], v)
        end
    end
@doc "Set `k` in the `attrs` field of the input object to `v`."
setattr!(d, v, keys...) = setindex!(attrs(d), v, keys...)
@doc "Check if `k` is present in the `attrs` field of the input object."
hasattr(d, k) = haskey(attrs(d), k)
@doc "Check if any of `keys...` is present in the `attrs` field of the input object."
hasattr(d, keys...) =
    let a = attrs(d)
        any(haskey(a, k) for k in keys)
    end

export shift!
export approxzero, gtxzero, ltxzero, negative, positive, inc!, dec!
export attrs, attr, hasattr, attr!, setattr!, modifyattr!
export isoffline, @skipoffline
