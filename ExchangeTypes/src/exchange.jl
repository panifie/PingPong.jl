using .Python: pyschedule, pytask, Python, pyisinstance, pygetattr, @pystr, pybuiltins, pydict
using Ccxt: _issupported
using Ccxt.Misc.Lang: @lget!
using Base: with_logger, NullLogger
using OrderedCollections: OrderedSet

@doc "Same as ccxt precision mode enums."
@enum ExcPrecisionMode excDecimalPlaces = 2 excSignificantDigits = 3 excTickSize = 4

@doc "Functions `f(::Exchange)` to call when an exchange is loaded"
const HOOKS = Dict{Symbol,Vector{Function}}()

@doc """Abstract exchange type.

Defines the interface for interacting with crypto exchanges. Implemented for CCXT in CcxtExchange.
"""
abstract type Exchange{I} end
const OptionsDict = Dict{String,Dict{String,Any}}

@doc """The `CcxtExchange` type wraps a ccxt exchange instance. Some attributes frequently accessed
are copied over to avoid round tripping python. More attributes might be added in the future.
To instantiate an exchange call `getexchange!` or `setexchange!`.

"""
mutable struct CcxtExchange{I<:ExchangeID} <: Exchange{I}
    const py::Py
    const id::I
    const name::String
    const account::String
    const timeframes::OrderedSet{String}
    const markets::OptionsDict
    const types::Set{Symbol}
    const fees::Dict{Symbol,Union{Symbol,<:Number,<:AbstractDict}}
    const has::Dict{Symbol,Bool}
    const params::Py
    precision::ExcPrecisionMode
    _trace::Any
end

@doc """ Closes the given exchange.

$(TYPEDSIGNATURES)

This function attempts to close the given exchange if it exists. It checks if the exchange has a 'close' attribute and if so, it schedules the 'close' coroutine for execution.
"""
function close_exc(exc::CcxtExchange)
    try
        k = (Symbol(exc.id), account(exc))
        if !haskey(exchanges, k) && !haskey(sb_exchanges, k) || pyisnull(e.py)
            return nothing
        end
        close_func = pygetattr(e, "close", nothing)
        if !isnothing(close_func)
            co = close_func()
            if !pyisnull(co) && pyisinstance(co, Python.gpa.pycoro_type)
                task = pytask(co)
                # block during precomp
                if ccall(:jl_generating_output, Cint, ()) == 1
                    wait(task)
                else
                    @async try
                        wait(task)
                    catch
                    end
                end
            end
        end
    catch e
        @debug e
    end
end

Exchange() = Exchange(pybuiltins.None)
@doc """ Instantiates a new `Exchange` wrapper for the provided `x` Python object.

This constructs a `CcxtExchange` struct with the provided Python object.
It extracts the exchange ID, name, and other metadata.
It runs any registered hook functions for that exchange.
It sets a finalizer to close the exchange when garbage collected.

Returns the new `Exchange` instance, or an empty one if `x` is None.
"""
function Exchange(x::Py, params=nothing, account="")
    id = ExchangeID(x)
    isnone = pyisnone(x)
    name = isnone ? "" : pyconvert(String, pygetattr(x, "name"))
    e = CcxtExchange{typeof(id)}(
        x,
        id,
        name,
        account,
        OrderedSet{String}(),
        OptionsDict(),
        Set{Symbol}(),
        Dict{Symbol,Union{Symbol,<:Number}}(),
        Dict{Symbol,Bool}(),
        @something(params, pydict()),
        excTickSize,
        nothing,
    )
    funcs = get(HOOKS, Symbol(id), ())::Union{Tuple{},Vector{Function}}
    for f in funcs
        f(e)
    end
    isnone ? e : finalizer(close_exc, e)
end

@doc """ Converts value v to integer size with precision p.
 $(TYPEDSIGNATURES)

Used when converting exchange API responses to integer sizes for orders.
"""
decimal_to_size(v, p::ExcPrecisionMode; exc=nothing) = begin
    if p == excDecimalPlaces
        if pyisinstance(v, pybuiltins.int)
            convert(Int, v)
        else
            @warn "exchanges: wrong precision mode" v p exc
            v
        end
    else
        v
    end
end

Base.isempty(e::Exchange) = Symbol(e.id) === Symbol()

@doc "The hash of an exchange object is reduced to its symbol (the function used to instantiate the object from ccxt)."
Base.hash(e::Exchange, u::UInt) = Base.hash(e.id, u)

@doc "Attributes not matching the `Exchange` struct fields are forwarded to the wrapped ccxt class instance."
function Base.getproperty(e::E, k::Symbol) where {E<:Exchange}
    if hasfield(E, k)
        getfield(e, k)
    else
        !isempty(e) || throw("Can't access non instantiated exchange object.")
        pyk = @pystr(k)
        pyv = getfield(e, :py)
        pygetattr(pyv, pyk)
    end
end
function Base.propertynames(e::E) where {E<:Exchange}
    (fieldnames(E)..., propertynames(e.py)...)
end

_has(exc::Exchange, syms::Vararg{Symbol}) = begin
    h = getfield(exc, :has)
    any(s -> get(h, s, false), syms)
end

_has(exc::Exchange, s::Symbol) = begin
    h = getfield(exc, :has)
    get(h, s, false)
end

@doc """
Checks if the specified feature `feat` is supported by any of the exchanges available through the ccxt library.

# Arguments
- `s::Symbol`: The feature to check for support across exchanges.
- `full::Bool=true`: If `true`, checks both static and instantiated properties of the exchange for support.

# Returns
- `Vector{String}`: A list of exchange names that support the specified feature.
"""
function _has(feat::Symbol; full=true)
    supported = String[]
    ccxt = Ccxt.ccxtws()
    feat = string(feat)
    for e in ccxt_exchange_names()
        name = string(e)
        if hasproperty(ccxt, name)
            cls = getproperty(ccxt, name)
            if (full && (_issupported(cls.has, feat) || _issupported(cls().has, feat))) ||
                _issupported(cls.has, feat)
                push!(supported, name)
            end
        end
    end
    supported
end
# NOTE: wrap the function here to quickly overlay methods
has(args...; kwargs...) = _has(args...; kwargs...)
_has_all(exc, what; kwargs...) = all((_has(exc, v; kwargs...)) for v in what)
# NOTE: wrap the function here to quickly overlay methods
has(exc, what::Tuple{Vararg{Symbol}}; kwargs...) = _has_all(exc, what; kwargs...)

account(exc::Exchange) = getfield(exc, :account)
params(exc::Exchange) = getfield(exc, :params)

function _first(exc::Exchange, args::Vararg{Symbol})
    for name in args
        has(exc, name) && return getproperty(getfield(exc, :py), name)
    end
end

@doc """Return the first available property from a variable number of Symbol arguments in the given Exchange.

$(TYPEDSIGNATURES)

This function iterates through the provided Symbols and returns the value of the first property that exists in the Exchange object."""
Base.first(exc::Exchange, args::Vararg{Symbol}) = _first(exc, args...)

@doc "Global var holding Exchange instances. Used as a cache."
const exchanges = Dict{Tuple{Symbol,String},Exchange}()
@doc "Global var holding Sandbox Exchange instances. Used as a cache."
const sb_exchanges = Dict{Tuple{Symbol,String},Exchange}()

_closeall() = begin
    @sync begin
        excs = []
        while !isempty(exchanges)
            _, e = pop!(exchanges)
            push!(excs, e)
            @async finalize(e)
        end
        while !isempty(sb_exchanges)
            _, e = pop!(sb_exchanges)
            push!(excs, e)
            @async finalize(e)
        end
    end
end

# atexit(_closeall)
Base.nameof(e::CcxtExchange) = Symbol(getfield(e, :id))

exchange(e::Exchange, args...; kwargs...) = e
exchangeid(e::E) where {E<:Exchange} = getfield(e, :id)

Base.print(out::IO, exc::Exchange) = begin
    write(out, "Exchange: ")
    write(out, exc.name)
    write(out, " | ")
    write(out, "$(length(exc.markets)) markets")
    write(out, " | ")
    tfs = collect(exc.timeframes)
    write(out, "$(length(tfs)) timeframes")
end
Base.display(exc::Exchange) = print(exc)
Base.show(out::IO, exc::Exchange) = print(out, ":", nameof(exc))
