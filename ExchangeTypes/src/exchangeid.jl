@doc "All possible exchanges that can be instantiated by ccxt."
const exchangeIds = Symbol[]

@doc """A structure for handling Exchange IDs in CCXT.

$(FIELDS)

This structure is used to manage Exchange IDs in the CCXT library. It contains methods for creating an Exchange ID from a symbol, a Python object, or directly from a symbol type. It ensures that the symbol is in the list of valid exchange IDs.
"""
struct ExchangeID{I}
    function ExchangeID(sym::Symbol=Symbol())
        sym == Symbol() && return new{sym}()
        if isempty(exchangeIds)
            prev = Set{Symbol}()
            for name in ccxt_exchange_names()
                id = Symbol(name)
                if id ∉ prev
                    push!(exchangeIds, id)
                    push!(prev, id)
                end
            end
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
    function ExchangeID{sym}() where {sym}
        ExchangeID(sym)
    end
end

const EIDType = Type{<:ExchangeID}
Base.getproperty(::T, ::Symbol) where {T<:ExchangeID} = T.parameters[1]
Base.nameof(::ExchangeID{T}) where {T} = T
Base.show(io::IO, id::ExchangeID) = begin
    write(io, "ExchangeID(:")
    write(io, id.sym)
    write(io, ")")
end
Base.convert(::Type{<:AbstractString}, id::ExchangeID) = string(id.sym)
Base.convert(::Type{Symbol}, id::ExchangeID) = id.sym
Base.Symbol(::Type{<:ExchangeID{T}}) where {T} = T
Base.Symbol(id::ExchangeID) = id.sym
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
import Base.==
==(id::ExchangeID, s::Symbol) = Base.isequal(nameof(id), s)

@doc "Create an ExchangeID instance from a symbol."
exchangeid(sym::Symbol) = ExchangeID(sym)
@doc "Return the given ExchangeID instance."
exchangeid(id::ExchangeID) = id
@doc "Union type of many exchange ids (from `Symbol` arguments)"
eids(ids...) = Union{((ExchangeID{i}) for i in ids)...}
