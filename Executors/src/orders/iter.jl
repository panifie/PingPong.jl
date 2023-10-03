using .Strategies: PriceTime
struct OrderIterator
    iters::Vector{Iterators.Stateful}
    OrderIterator(args...) = new([Iterators.Stateful(a) for a in args])
    OrderIterator(gen) = OrderIterator([Iterators.Stateful(a) for a in gen])
end


_findmin(non_empty_iters) = begin
    # Find the iterator with the smallest value
    min_iter = non_empty_iters[1]
    min_val = peek(min_iter)

    for iter in non_empty_iters[2:end]
        val = peek(iter)
        if val.first < min_val.first
            min_val = val
            min_iter = iter
        end
    end

    (min_val, min_iter)
end

_do_orders_iter(oi) = begin
    # Filter out empty iterators
    non_empty_iters = filter!(!isempty, oi.iters)

    # Check if all iterators are empty
    if isempty(non_empty_iters)
        return nothing
    end

    min_val, min_iter = _findmin(non_empty_iters)

    # Remove the smallest value from the iterator and return it
    popfirst!(min_iter)
    return (min_val, nothing)
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
