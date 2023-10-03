using .Strategies: PriceTime
struct OrderIterator
    iters::Vector{Iterators.Stateful}
    OrderIterator(args...) = new([Iterators.Stateful(a) for a in args])
    OrderIterator(gen) = OrderIterator([Iterators.Stateful(a) for a in gen])
end

# Find the iterator with the smallest value
_findmin(non_empty_iters) = begin
    iters = @view non_empty_iters[2:end]
    min_val, iter_idx = findmin(peek, iters)
    min_val, iters[iter_idx]
end

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

Base.iterate(oi::OrderIterator, _) = _do_orders_iter(oi)
Base.iterate(oi::OrderIterator) = _do_orders_iter(oi)
Base.isdone(oi::OrderIterator) = isempty(oi.iters)
Base.eltype(::OrderIterator) = Pair{PriceTime,<:Order}
function Base.collect(oi::OrderIterator)
    let out = Vector{eltype(oi)}()
        push!(out, (v for v in oi)...)
    end
end
Base.last(oi::OrderIterator) =
    let out = first(oi)
        for v in oi
            out = v
        end
        out
    end
Base.count(oi::OrderIterator) = count((_) -> true, oi)
