@doc """A view into a dictionary (a subset of keys).

$(FIELDS)
"""
@kwdef struct DictView6{K,D}
    d::D
    keys::Set{K}
end
DictView = DictView6
dictview(d, keys) = DictView(d, Set(keys))

@doc """Macro for checking if a key exists in a `DictView`.

This macro checks if a given key is present in the `keys` field of the `DictView` (`d`).
"""
macro checkkey(k)
    k = esc(k)
    quote
        $k ∈ $(esc(:d)).keys || throw(KeyError($k))
    end
end
Base.getindex(d::DictView, k) = begin
    @checkkey k
    getindex(d.d, k)
end
Base.setindex!(d::DictView, k) = begin
    @checkkey k
    setindex!(d.d, k)
end
Base.delete!(d::DictView, k) = begin
    @checkkey k
    delete!(d.d, k)
end
Base.empty!(d::DictView) = begin
    for k in d.keys
        delete!(d.d, k)
    end
end
Base.isempty(d::DictView) = isempty(d.keys)
Base.length(d::DictView) = length(d.keys)
Base.keys(d::DictView) = d.keys
Base.values(d::DictView) = [d.d[k] for k in d.keys]
Base.haskey(d::DictView, k) = k in d.keys
Base.get(d::DictView, k, def) =
    if k in d.keys
        getindex(d.d, k)
    else
        def
    end
@kwdef struct DictViewIterator2
    current::Vector{Int} = [2]
    stop::Int
end
Base.iterate(d::DictView) = Iterators.peel((k, d.d[k]) for k in d.keys)
Base.iterate(::DictView, state) = Iterators.peel(state)
Base.filter(f, d::DictView) = Dict(p for p in d if f(p))
