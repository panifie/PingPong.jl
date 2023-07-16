using Python: pyschedule, pywait_fut, Python, pyisinstance
using Python: @tspawnat
using Base: with_logger, NullLogger

@doc "Same as ccxt precision mode enums."
@enum ExcPrecisionMode excDecimalPlaces = 2 excSignificantDigits = 3 excTickSize = 4

abstract type Exchange{I} end
const OptionsDict = Dict{String,Dict{String,Any}}
@doc """The exchange type wraps a ccxt exchange instance. Some attributes frequently accessed
are copied over to avoid round tripping python. More attributes might be added in the future.
To instantiate an exchange call `getexchange!` or `setexchange!`.

"""
mutable struct CcxtExchange{I<:ExchangeID} <: Exchange{I}
    const py::Py
    const id::I
    const name::String
    const precision::Vector{ExcPrecisionMode}
    const timeframes::Set{String}
    const markets::OptionsDict
    const types::Set{Symbol}
    const has::Dict{Symbol,Bool}
end

function close_exc(exc::CcxtExchange)
    (haskey(exchanges, nameof(exc.id)) || haskey(sb_exchanges, nameof(exc.id))) &&
        return nothing
    e = exc.py
    if !pyisnull(e) && pyhasattr(e, "close")
        co = e.close()
        if !pyisnull(co) && pyisinstance(co, Python.gpa.pycoro_type)
            fut = pyschedule(co)
            pywait_fut(fut)
        end
    end
end

Exchange() = Exchange(pybuiltins.None)
function Exchange(x::Py)
    id = ExchangeID(x)
    isnone = pyisnone(x)
    name = isnone ? "" : pyconvert(String, pygetattr(x, "name"))
    e = CcxtExchange{typeof(id)}(
        x,
        id,
        name,
        [excDecimalPlaces],
        Set{String}(),
        OptionsDict(),
        Set{Symbol}(),
        Dict{Symbol,Bool}(),
    )
    isnone ? e : finalizer(close_exc, e)
end

Base.isempty(e::Exchange) = nameof(e.id) === Symbol()

@doc "The hash of an exchange object is reduced to its symbol (the function used to instantiate the object from ccxt)."
Base.hash(e::Exchange, u::UInt) = Base.hash(e.id, u)

@doc "Attributes not matching the `Exchange` struct fields are forwarded to the wrapped ccxt class instance."
function Base.getproperty(e::E, k::Symbol) where {E<:Exchange}
    if hasfield(E, k)
        if k == :precision
            getfield(e, k)[1]
        else
            getfield(e, k)
        end
    else
        !isempty(e) || throw("Can't access non instantiated exchange object.")
        getproperty(getfield(e, :py), k)
    end
end
function Base.propertynames(e::E) where {E<:Exchange}
    (fieldnames(E)..., propertynames(e.py)...)
end

has(exc::Exchange, s::Symbol) =
    let h = getfield(exc, :has)
        haskey(h, s) && h[s]
    end
function Base.first(exc::Exchange, args::Vararg{Symbol})
    for a in args
        has(exc, a) && return getproperty(getfield(exc, :py), a)
    end
end

@doc "Updates the global exchange `exc` variable."
globalexchange!(new::Exchange) = begin
    global exc
    exc = new
    exc
end

@doc "Global var implicit exchange instance.

When working interactively, a global `exc` variable is available, updated through `globalexchange!`, which
is used as the default for some functions when the exchange argument is omitted."
exc = Exchange()
@doc "Global var holding Exchange instances. Used as a cache."
const exchanges = Dict{Symbol,Exchange}()
@doc "Global var holding Sandbox Exchange instances. Used as a cache."
const sb_exchanges = Dict{Symbol,Exchange}()

_closeall() = begin
    @sync begin
        while !isempty(exchanges)
            _, e = pop!(exchanges)
            @tspawnat 1 finalize(e)
        end
        while !isempty(sb_exchanges)
            _, e = pop!(sb_exchanges)
            @tspawnat 1 finalize(e)
        end
    end
end

atexit(_closeall)

exchange(args...; kwargs...) = error("not implemented")

Base.show(out::IO, exc::Exchange) = begin
    write(out, "Exchange: ")
    write(out, exc.name)
    write(out, " | ")
    write(out, "$(length(exc.markets)) markets")
    write(out, " | ")
    tfs = collect(exc.timeframes)
    write(out, "$(length(tfs)) timeframes")
end
