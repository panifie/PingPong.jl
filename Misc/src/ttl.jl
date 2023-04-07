module TimeToLive

export TTL

using Base.Iterators: peel
using Dates: DateTime, Period, now

struct Node{T}
    value::T
    expiry::DateTime
end

isexpired(v::Node) = now() > v.expiry
isexpired(time::DateTime) = v::Node -> time > v.expiry

"""
    TTL(ttl::Period; refresh_on_access::Bool=true)
    TTL{K, V}(ttl::Period; refresh_on_access::Bool=true)

An associative [TTL](https://en.wikipedia.org/wiki/Time_to_live) cache.
If `refresh_on_access` is set, expiries are reset whenever they are accessed.
"""
struct TTL{K, V, P<:Period} <: AbstractDict{K, V}
    dict::Dict{K, Node{V}}
    ttl::P
    refresh::Bool

    TTL{K, V}(ttl::P; refresh_on_access::Bool=true) where {K, V, P <: Period} =
        new{K, V, P}(Dict{K, Node{V}}(), ttl, refresh_on_access)
    TTL(ttl::Period; refresh_on_access::Bool=true) =
        TTL{Any, Any}(ttl; refresh_on_access=refresh_on_access)
end

Base.delete!(t::TTL, key) = (delete!(t.dict, key); t)
Base.empty!(t::TTL) = (empty!(t.dict); t)
Base.get(f, t::TTL, key) = haskey(t, key) ? t[key] : f()
Base.get!(t::TTL, key, default) = haskey(t, key) ? t[key] : (t[key] = default)
Base.length(t::TTL) = count(!isexpired(now()), values(t.dict))
Base.push!(t::TTL, p::Pair) = (t[p.first] =  p.second; t)
Base.setindex!(t::TTL{K, V}, v, k) where {K, V} = t.dict[k] = Node{V}(v, now() + t.ttl)
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
