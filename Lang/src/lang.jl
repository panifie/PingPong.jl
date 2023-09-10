using Distributed: Distributed, @distributed
using Logging: Logging, with_logger, NullLogger
using SnoopPrecompile

const Option{T} = Union{Nothing,T} where {T}

macro preset(code)
    :(@precompile_setup $(esc(code)))
end
macro precomp(code)
    :(@precompile_all_calls $(esc(code)))
end

macro parallel(flag, body)
    b = esc(body)
    db = esc(:(@distributed $body))
    quote
        if $(esc(flag))
            $db
        else
            $b
        end
    end
end

passkwargs(args...) = [Expr(:kw, a.args[1], a.args[2]) for a in args]

macro passkwargs(args...)
    kwargs = [Expr(:kw, a.args[1], a.args[2]) for a in args]
    return esc(:($(kwargs...)))
end

@doc "Returns only the keywords `kws...` from all the `kwargs`"
filterkws(kws...; kwargs, pred=∈) = begin
    ((k, v) for (k, v) in kwargs if pred(k, (kws...,)))
end

@doc "Splits the keywords `kws...` from all the `kwargs`, returning the tuple `(filtered, rest)`."
function splitkws(kws...; kwargs)
    (filtered=filterkws(kws...; kwargs), rest=filterkws(kws...; kwargs, pred=∉))
end

@doc """Get a value from a container that *should not contain* `nothing`, lazily evaluating the default value.
```julia
> @get Dict("a" => false) "a" (println("hello"); true)
false
> Lang.@get Dict("a" => false) "b" (println("hello"); true)
hello
true
```
"""
macro get(dict, k, expr)
    dict = esc(dict)
    expr = esc(expr)
    k = esc(k)
    :(@something get($dict, $k, nothing) $expr)
end

@doc "Lazy *get or set* for a container key-value pair that *should not contain* `missing`."
macro lget!(dict, k, expr)
    dict = esc(dict)
    expr = esc(expr)
    k = esc(k)
    quote
        @coalesce get($dict, $k, missing) let v = $expr
            $dict[$k] = v
            v
        end
    end
end

@doc """Get the first available key from a container, or a default (last) value.
```julia
> @multiget Dict("k" => 1) "a" "b" false
false
> @multiget Dict("k" => 1, "b" => 2) "a" "b" false
2
```
"""
macro multiget(dict, args...)
    dict = esc(dict)
    if length(args) < 2
        throw(ArgumentError("Not enough args in macro call."))
    end
    expr = esc(args[end])
    result = :(@something)
    for k in args[begin:(end - 1)]
        push!(result.args, :(get($dict, $(esc(k)), nothing)))
    end
    push!(result.args, expr)
    result
end

@doc "Use this in loops instead of `@lget!`"
macro kget!(dict, k, expr)
    dict = esc(dict)
    expr = esc(expr)
    k = esc(k)
    quote
        if haskey($dict, $k)
            $dict[$k]
        else
            v = $expr
            $dict[$k] = v
            v
        end
    end
end

@doc "Define a new symbol with given value if it is not already defined."
macro ifundef(name, val, mod=__module__)
    name_var = esc(name)
    name_sym = esc(:(Symbol($(string(name)))))
    quote
        if isdefined($mod, $name_sym)
            $name_var = getproperty($mod, $name_sym)
        else
            $name_var = $val
        end
    end
end

macro as(sym, val)
    s = esc(sym)
    v = esc(val)
    quote
        $s = $v
        true
    end
end

@doc "`fromdict` tries to fill a _known_ `NamedTuple` from an _unknown_ `Dict`."
@generated function fromdict(tuple, key, di, kconvfunc=convert, convfunc=convert)
    params = Expr(:parameters)
    ex = Expr(:tuple, params)
    ttype = first(tuple.parameters)
    ktype = isempty(key.parameters) ? key : first(key.parameters)
    for (fi, ty) in zip(fieldnames(ttype), fieldtypes(ttype))
        p = Expr(:kw, fi, :(convfunc($ty, (di[kconvfunc($ktype, $(QuoteNode(fi)))]))))
        push!(params.args, p)
    end
    ex
end

@doc "Converts a struct into a named tuple."
function fromstruct(c::T) where {T}
    names = fieldnames(T)
    nt = NamedTuple{names,Tuple{fieldtypes(T)...}}
    t = (getfield(c, f) for f in names)
    nt(t)
end

@doc "A string literal as a symbol."
macro sym_str(s)
    :(Symbol($s))
end

@doc "A `MatchString` should be used to dispatch string specific functions with some supertype context."
struct MatchString{S<:AbstractString}
    s::S
end
@doc "A string literal as a `MatchString`."
macro m_str(s)
    :(MatchString($s))
end

_asbool(v::Bool, args...) = v
function _asbool(v::String, name)
    @something tryparse(Bool, v) occursin(name, v) v == "all"
end
function _isdebug(name)
    @something _asbool((@something get(ENV, "JULIA_DEBUG", nothing) false), name) false
end

macro ifdebug(a, b=nothing)
    name = string(__module__)
    esc(_isdebug(name) ? a : b)
end

macro deassert(condition, msg=nothing)
    name = string(__module__)
    if _isdebug(name)
        if isnothing(msg)
            quote
                # @assert $(esc(condition))
                @assert $(esc(condition)) $(string(condition))
            end
        else
            quote
                @assert $(esc(condition)) $(esc(msg))
            end
        end
    end
end

@doc "`errormonitor` wrapped `@async` call."
macro asyncm(expr)
    :(errormonitor(@async $(esc(expr))))
end

@doc "Sets property `prop` on object `a` to value `val` if `op(a.prop, val)` is `true`."
function ifproperty!(op, a, prop, val)
    op(getproperty(a, prop), val) && setproperty!(a, prop, val)
end
@doc "Sets key `k` on object `a` to value `val` if `op(a[k], val)` is `true`."
function ifkey!(op, a, k, val)
    op(get!(a, k, val), val) && setindex!(a, val, k)
end

@doc "Notify a condition with locks."
safenotify(cond, args...; kwargs...) = begin
    lock(cond) do
        notify(cond, args...; kwargs...)
    end
end
@doc "Wait a condition with locks."
safewait(cond) = begin
    lock(cond) do
        wait(cond)
    end
end
@doc "Same as `@lock` but with `acquire` and `release`."
macro acquire(cond, code)
    quote
        temp = $(esc(cond))
        Base.acquire(temp)
        try
            $(esc(code))
        catch e
            e
        finally
            Base.release(temp)
        end
    end
end

macro buffer!(v, code)
    quote
        buf = IOBuffer($(esc(v)))
        try
            $(esc(code))
        finally
            close(buf)
        end
    end
end

macro argstovec(fname, type, outf=identity)
    fname = esc(fname)
    type = esc(type)
    quote
        $fname(args::$type...; kwargs...) = $outf($fname([args...]; kwargs...))
    end
end

@doc "Toggles a boolean property."
function toggle!(value, name)
    setproperty!(value, name, ifelse(getproperty(value, name), false, true))
end

@doc "Waits for ref to be true."
function waitref(flag::Ref)
    while !(flag[])
        sleep(0.001)
    end
end

@doc "Waits for function to return true."
function waitfunc(flag::Function)
    while !(flag())
        sleep(0.001)
    end
end

@doc "Throws if all inputs aren't positive (only in debug)."
macro posassert(args...)
    quote
        @ifdebug for a in $(esc.(args)...)
            @assert a >= 0.0
        end
    end
end

macro logerror(fileexpr)
    quote
        open($(esc(fileexpr)), "a") do f
            $(@__MODULE__).@writeerror(f)
        end
    end
end

macro writeerror(filehandle)
    quote
        f = $(esc(filehandle))
        println(f, string($(__module__).Dates.now()))
        Base.showerror(f, $(esc(:e)))
        Base.show_backtrace(f, Base.catch_backtrace())
        flush(f)
    end
end

macro debug_backtrace()
    quote
        let buf = IOBuffer()
            try
                error, trace = first(Base.catch_stack())
                Base.show_backtrace(buf, trace)
                @debug String(take!(buf)) error = error
            finally
                close(buf)
            end
        end
    end
end

export @preset, @precomp
export @kget!, @lget!
export @passkwargs, passkwargs, filterkws, splitkws
export @as, @sym_str, @exportenum
export Option, toggle, @asyncm, @ifdebug, @deassert, @argstovec, @debug_backtrace
