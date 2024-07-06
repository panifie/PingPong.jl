using .Strategies: PriceTime
import .Instances: trades

@doc """
A data structure for maintaining a collection of iterators.

$(FIELDS)
"""
struct OrderIterator
    iters::Vector{Iterators.Stateful}  # Vector of `Iterators.Stateful`
    OrderIterator(args...) = new([Iterators.Stateful(a) for a in args])
    OrderIterator(gen) = new([Iterators.Stateful(a) for a in gen])
end

@doc """
Finds and returns the iterator with the smallest value.

$(TYPEDSIGNATURES)
"""
_findmin(non_empty_iters) = begin
    iters = @view non_empty_iters[2:end]
    min_val, iter_idx = findmin(peek, iters)
    min_val, iters[iter_idx]
end

@doc """
Filters out empty iterators and returns the smallest value.

$(TYPEDSIGNATURES)
"""
_do_orders_iter(oi) = begin
    # Filter out empty iterators
    non_empty_iters = filter!(!isempty, oi.iters)

    # Check if all iterators are empty
    len = length(non_empty_iters)
    if len == 0
        nothing
    elseif len == 1
        popfirst!(non_empty_iters[1]), nothing
    else
        min_val, min_iter = _findmin(non_empty_iters)

        # Remove the smallest value from the iterator and return it
        popfirst!(min_iter)
        min_val, nothing
    end
end

@doc """
Returns the next element in the OrderIterator.

$(TYPEDSIGNATURES)
"""
Base.iterate(oi::OrderIterator, _) = _do_orders_iter(oi)
Base.iterate(oi::OrderIterator) = _do_orders_iter(oi)
Base.length(oi::OrderIterator) = sum(length(i) for i in oi.iters)

@doc """
Checks if the OrderIterator is empty.

$(TYPEDSIGNATURES)
"""
Base.isdone(oi::OrderIterator) = isempty(oi.iters)

@doc """
Returns the element type of the OrderIterator.

$(TYPEDSIGNATURES)
"""
Base.eltype(::OrderIterator) = Pair{PriceTime,<:Order}

@doc """
Collects all elements of the OrderIterator into a Vector.

$(TYPEDSIGNATURES)
"""
function Base.collect(oi::OrderIterator)
    let out = Vector{eltype(oi)}()
        push!(out, (v for v in oi)...)
    end
end

@doc """
Returns the last element in the OrderIterator.

$(TYPEDSIGNATURES)
"""
Base.last(oi::OrderIterator) =
    let out = first(oi)
        for v in oi
            out = v
        end
        out
    end

@doc """
Counts the number of elements in the OrderIterator.

$(TYPEDSIGNATURES)
"""
Base.count(oi::OrderIterator) = count((_) -> true, oi)

trades(s::Strategy) = Iterators.flatten(trades(ai) for ai in s.universe)
tradescount(s::Strategy) = sum(length(trades(ai)) for ai in s.universe)
closed_orders(s::Strategy) = (o for o in values(s) if !isopen(asset_bysym(s, raw(o.asset)), o))