module ExchangeTypes
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using Ccxt
using Python: Py, pybuiltins, pyconvert, Python, pyhasattr, pygetattr
using Python.PythonCall: pyisnone, pyisnull
using FunctionalCollections
using Lang: Option, waitfunc, @preset, @precomp

@doc "All possible exchanges that can be instantiated by ccxt."
const exchangeIds = Symbol[]

@doc "An ExchangeID is a symbol checked to match a ccxt exchange class."
struct ExchangeID{I}
    function ExchangeID(sym::Symbol=Symbol())
        sym == Symbol() && return new{sym}()
        if isempty(exchangeIds)
            append!(
                exchangeIds,
                (x -> PersistentSet{Symbol}(x))(
                    pyconvert(Vector{Symbol}, ccxt[].exchanges)
                ),
            )
            @assert sym ∈ exchangeIds
        else
            @assert sym ∈ exchangeIds
        end
        new{sym}()
    end
    function ExchangeID(py::Py)
        s = if pyisnone(py)
            ""
        else
            (pyhasattr(py, "__name__") ? py.__name__ : py.__class__.__name__)
        end
        ExchangeID(pyconvert(Symbol, s))
    end
end
Base.getproperty(::T, ::Symbol) where {T<:ExchangeID} = T.parameters[1]
Base.nameof(::T) where {T<:ExchangeID} = T.parameters[1]
Base.show(io::IO, id::ExchangeID) = begin
    write(io, "ExchangeID(:")
    write(io, id.sym)
    write(io, ")")
end
Base.convert(::Type{<:AbstractString}, id::ExchangeID) = string(id.sym)
Base.convert(::Type{Symbol}, id::ExchangeID) = id.sym
Base.string(id::ExchangeID) = string(id.sym)
function Base.display(
    ids::T
) where {T<:Union{AbstractVector{ExchangeID},AbstractSet{ExchangeID}}}
    s = String[]
    for id in ids
        push!(s, string(id.sym))
    end
    Base.display(s)
end
Base.Broadcast.broadcastable(q::ExchangeID) = Ref(q)
# import Base.==
# ==(id::ExchangeID, s::Symbol) = Base.isequal(nameof(id), s)

@doc "Same as ccxt precision mode enums."
@enum ExcPrecisionMode excDecimalPlaces = 2 excSignificantDigits = 3 excTickSize = 4

const OptionsDict = Dict{String,Dict{String,Any}}
struct Exchange8{I<:ExchangeID}
    py::Py
    id::I
    name::String
    precision::Vector{ExcPrecisionMode}
    timeframes::Set{String}
    markets::OptionsDict
    Exchange8() = new{typeof(ExchangeID())}(pybuiltins.None) # FIXME: this should be None
    function Exchange8(x::Py)
        id = ExchangeID(x)
        name = pyisnone(x) ? "" : pyconvert(String, pygetattr(x, "name"))
        new{typeof(id)}(x, id, name, [excDecimalPlaces], Set(), Dict())
    end
end
@doc """The exchange type wraps a ccxt exchange instance. Some attributes frequently accessed
are copied over to avoid round tripping python. More attributes might be added in the future.
To instantiate an exchange call `getexchange!` or `setexchange!`.

"""
Exchange = Exchange8

Base.isempty(e::Exchange) = nameof(e.id) === Symbol()

@doc "The hash of an exchange object is reduced to its symbol (the function used to instantiate the object from ccxt)."
Base.hash(e::Exchange, u::UInt) = Base.hash(e.id, u)

@doc "Attributes not matching the `Exchange` struct fields are forwarded to the wrapped ccxt class instance."
function Base.getproperty(e::Exchange, k::Symbol)
    if hasfield(Exchange, k)
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
function Base.propertynames(e::Exchange)
    (fieldnames(Exchange)..., propertynames(e.py)...)
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
exc = Exchange(pybuiltins.None)
@doc "Global var holding Exchange instances. Used as a cache."
const exchanges = Dict{Symbol,Exchange}()
@doc "Global var holding Sandbox Exchange instances. Used as a cache."
const sb_exchanges = Dict{Symbol,Exchange}()

Base.show(out::IO, exc::Exchange) = begin
    write(out, "Exchange: ")
    write(out, exc.name)
    write(out, " | ")
    write(out, "$(length(exc.markets)) markets")
    write(out, " | ")
    tfs = collect(exc.timeframes)
    write(out, "$(length(tfs)) timeframes")
end

export Exchange, ExchangeID, ExcPrecisionMode, exchanges, sb_exchanges, globalexchange!

function __init__()
    waitfunc(Ccxt.isinitialized)
    @assert !pyisnull(ccxt[])
end

@preset let
    e = :bybit
    @precomp begin
        __init__()
        ExchangeID(e)
    end
    id = ExchangeID(e)
    @precomp begin
        nameof(id)
        string(id)
        id.sym
        id == :bybit
        convert(Symbol, id)
        convert(String, id)
    end
    @precomp Exchange(ccxt[].bybit())
    e = Exchange(ccxt[].bybit())
    @precomp begin
        hash(e)
        e.has
    end
end

end # module ExchangeTypes
