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
Base.nameof(::Union{T,Type{T}}) where {T<:ExchangeID} = T.parameters[1]
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
import Base.==
==(id::ExchangeID, s::Symbol) = Base.isequal(nameof(id), s)

exchangeid(v) = error("not implemented")
