module ExchangeTypes
using Python
using Python: pynew, pyisnull
using FunctionalCollections
using Ccxt: ccxt

struct ExchangeID
    sym::Symbol
    ExchangeID(sym::Symbol=Symbol()) = begin
        sym == Symbol() && return new(sym)
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
        new(sym)
    end
    ExchangeID(py::Py) = begin
        s = pyisnull(py) ? "" : (pyhasattr(py, "__name__") ? py.__name__ : py.__class__.__name__)
        ExchangeID(pyconvert(Symbol, s))
    end
end
Base.display(id::ExchangeID) = Base.display(id.sym)
Base.convert(::T, id::ExchangeID) where {T<:AbstractString} = string(id.sym)
Base.string(id::ExchangeID) = string(id.sym)
function Base.display(ids::T) where {T<:Union{AbstractVector{ExchangeID},AbstractSet{ExchangeID}}}
    s = String[]
    for id in ids
        push!(s, string(id.sym))
    end
    Base.display(s)
end
Base.Broadcast.broadcastable(q::ExchangeID) = Ref(q)
import Base.==
==(e::ExchangeID, s::Symbol) = Base.isequal(e.sym, s)

const OptionsDict = Dict{String,Dict{String,Any}}
mutable struct Exchange
    py::Py
    isset::Bool
    timeframes::Set{String}
    name::String
    sym::ExchangeID
    markets::OptionsDict
    Exchange() = new(pynew()) # FIXME: this should be None
    Exchange(x::Py) = sym = new(x, false, Set(), "", ExchangeID(x), Dict())
end
@doc "The hash of an exchange object is reduced to its symbol (the function used to instantiate the object from ccxt)."
Base.hash(e::Exchange, u::UInt) = Base.hash(e.sym, u)
function Base.getproperty(e::Exchange, k::Symbol)
    if hasfield(Exchange, k)
        getfield(e, k)
    else
        getfield(e, :isset) || throw("Can't access non instantiated exchange object.")
        getproperty(getfield(e, :py), k)
    end
end

@doc "Global implicit exchange instance."
const exc = Exchange(pynew())
@doc "Global holding Exchange instances to avoid dups."
const exchanges = Dict{Symbol,Exchange}()

export Exchange, ExchangeID, exc, exchanges
end # module ExchangeTypes
