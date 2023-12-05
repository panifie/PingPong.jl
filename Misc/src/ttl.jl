@doc """ Module for managing time-to-live cache.

"""
module TimeToLive
using ConcurrentCollections: modify!, Delete, ConcurrentDict

export TTL, safettl

using Base.Iterators: peel
using Dates: DateTime, Period, now
using ..DocStringExtensions

struct Node{T}
    value::T
    expiry::DateTime
end

isexpired(v::Node) = now() > v.expiry
isexpired(time::DateTime) = v::Node -> time > v.expiry

@doc """
    TTL(ttl::Period; refresh_on_access::Bool=false)
    TTL{K, V}(ttl::Period; refresh_on_access::Bool=false)

$(TYPEDFIELDS)

An associative [TTL](https://en.wikipedia.org/wiki/Time_to_live) cache.
If `refresh_on_access` is set, expiries are reset whenever they are accessed.
"""
struct TTL{K,V,D<:AbstractDict,P<:Period} <: AbstractDict{K,V}
    dict::D where {D<:AbstractDict{K,Node{V}}}
    ttl::P
    refresh::Bool

    function TTL{K,V}(
        ttl::P; refresh_on_access::Bool=false, dict_type=Dict
    ) where {K,V,P<:Period}
        new{K,V,dict_type,P}(dict_type{K,Node{V}}(), ttl, refresh_on_access)
    end
    function TTL(ttl::Period; refresh_on_access::Bool=false)
        TTL{Any,Any}(ttl; refresh_on_access=refresh_on_access)
    end
end

@doc """ Safely instantiate a TTL dictionary.

$(TYPEDSIGNATURES)

This function safely creates a Time-to-Live (TTL) dictionary with specified key and value types, along with an optional ttl parameter.
"""
function safettl(K::Type, V::Type, ttl; kwargs...)
    TTL{K,V}(ttl; dict_type=ConcurrentDict, kwargs...)
end

Base.delete!(t::TTL, key) = (delete!(t.dict, key); t)
Base.empty!(t::ConcurrentDict{K,V}) where {K,V} =
    for k in keys(t)
        modify!(t, k) do value
            Delete(value)
        end
    end
Base.delete!(t::ConcurrentDict{K,V}, k) where {K,V} =
    modify!(t, k) do value
        Delete(value)
    end

Base.empty!(t::TTL) = (empty!(t.dict); t)
# Specifying ::Function fixes some method invalidations
Base.get(f::Function, t::TTL, key) = haskey(t, key) ? t[key] : f()
Base.get!(t::TTL, key, default) = haskey(t, key) ? t[key] : (t[key] = default)
Base.length(t::TTL) = count(!isexpired(now()), values(t.dict))
Base.push!(t::TTL, p::Pair) = (t[p.first] = p.second; t)
Base.setindex!(t::TTL{K,V}, v, k) where {K,V} = t.dict[k] = Node{V}(v, now() + t.ttl)
Base.sizehint!(t::TTL, newsz) = (sizehint!(t.dict, newsz); t)

function Base.pop!(t::TTL)
    p = pop!(t.dict)
    return isexpired(p.second) ? pop!(t) : p.first => p.second.value
end

function Base.pop!(t::TTL, key)
    v = pop!(t.dict, key)
    isexpired(v) && throw(KeyError(key))
    return v.value
end

function Base.get(t::TTL, key, default)
    haskey(t.dict, key) || return default
    v = t.dict[key]
    if isexpired(v)
        delete!(t, key)
        return default
    end
    t.refresh && (t[key] = v.value)
    return v.value
end

function Base.getkey(t::TTL, key, default)
    return if haskey(t, key)
        if isexpired(t.dict[key])
            delete!(t, key)
            default
        else
            key
        end
    else
        default
    end
end

function Base.iterate(t::TTL, ks=keys(t.dict))
    isempty(ks) && return nothing
    k, rest = peel(ks)
    v = t.dict[k]
    return if isexpired(v)
        delete!(t, k)
        iterate(t, rest)
    else
        k => v.value, rest
    end
end

function Base.getindex(t::TTL, key)
    v = t.dict[key]
    if isexpired(v)
        delete!(t, key)
        throw(KeyError(key))
    elseif t.refresh
        t[key] = v.value
    end
    return v.value
end

end
