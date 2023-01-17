module ExchangeTypes
using Python
using Python: pynew, pyisnull
using FunctionalCollections
using Ccxt: ccxt
using Lang: Option

struct ExchangeID{I}
    ExchangeID(sym::Symbol=Symbol()) = begin
        sym == Symbol() && return new{sym}()
        if !isdefined(@__MODULE__, :exchangeIds)
            @eval begin
                @doc "All possible exchanges that can be instantiated by ccxt."
                const exchangeIds =
                    pyconvert(Vector{Symbol}, ccxt.exchanges) |>
                    x -> PersistentSet{Symbol}(x)
            end
            @assert sym ∈ exchangeIds
        else
            @assert sym ∈ exchangeIds
        end
        new{sym}()
    end
    ExchangeID(py::Py) = begin
        s = if pyisnull(py)
            ""
        else
            (pyhasattr(py, "__name__") ? py.__name__ : py.__class__.__name__)
        end
        ExchangeID(pyconvert(Symbol, s))
    end
end
Base.getproperty(::T, ::Symbol) where {T<:ExchangeID} = T.parameters[1]
Base.nameof(::T) where {T<:ExchangeID} = T.parameters[1]
Base.display(id::ExchangeID) = Base.display(id.sym)
Base.convert(::T, id::ExchangeID) where {T<:AbstractString} = string(id.sym)
Base.convert(::Type{Symbol}, id::ExchangeID) = id.sym
Base.string(id::ExchangeID) = string(id.sym)
function Base.display(
    ids::T,
) where {T<:Union{AbstractVector{ExchangeID},AbstractSet{ExchangeID}}}
    s = String[]
    for id in ids
        push!(s, string(id.sym))
    end
    Base.display(s)
end
Base.Broadcast.broadcastable(q::ExchangeID) = Ref(q)
import Base.==
==(id::ExchangeID, s::Symbol) = Base.isequal(nameof(id), s)

@enum ExcPrecisionMode excDecimalPlaces = 2 excSignificantDigits = 3 excTickSize = 4

const OptionsDict = Dict{String,Dict{String,Any}}
struct Exchange8{I<:ExchangeID}
    py::Py
    id::I
    name::String
    precision::Vector{ExcPrecisionMode}
    timeframes::Set{String}
    markets::OptionsDict
    Exchange8() = new{typeof(ExchangeID())}(pynew()) # FIXME: this should be None
    Exchange8(x::Py) = begin
        id = ExchangeID(x)
        name = pyisnull(x) ? "" : pyconvert(String, pygetattr(x, "name"))
        new{typeof(id)}(x, id, name, [excDecimalPlaces], Set(), Dict())
    end
end
Exchange = Exchange8

Base.isempty(e::Exchange) = nameof(e.id) === Symbol()

@doc "The hash of an exchange object is reduced to its symbol (the function used to instantiate the object from ccxt)."
Base.hash(e::Exchange, u::UInt) = Base.hash(e.id, u)
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

globalexchange!(new::Exchange) = begin
    global exc
    exc = new
    exc
end


@doc "Global implicit exchange instance."
exc = Exchange(pynew())
@doc "Global holding Exchange instances to avoid dups."
const exchanges = Dict{Symbol,Exchange}()

Base.display(exc::Exchange) = begin
    out = IOBuffer()
    try
        write(out, "Exchange: ")
        write(out, exc.name)
        write(out, " | ")
        write(out, "$(length(exc.markets)) markets")
        write(out, " | ")
        tfs = collect(exc.timeframes)
        write(out, "$(length(tfs)) timeframes")
        Base.print(String(take!(out)))
    finally
        close(out)
    end
end

export Exchange, ExchangeID, ExcPrecisionMode, exchanges, globalexchange!
end # module ExchangeTypes
