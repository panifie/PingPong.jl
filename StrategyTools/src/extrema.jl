@doc """
MovingExtrema2: keep track of minimum and maximum values within a moving window.
$(TYPEDSIGNATURES)
"""
struct MovingExtrema
    window::Int
    values::Deque{Float64}  # Store the actual values for reference
    minima::Deque{Float64}  # Candidates for minimum
    maxima::Deque{Float64}  # Candidates for maximum
end

@doc """
MovingExtrema2: Keep track of minima and maxima within a moving window.
$(TYPEDSIGNATURES)
"""
function MovingExtrema(window::Int)
    return MovingExtrema(window, Deque{Float64}(), Deque{Float64}(), Deque{Float64}())
end
@doc """
Pushes a new value to the MovingExtrema2 buffer.
$(TYPEDSIGNATURES)
"""
function Base.push!(q::MovingExtrema, value::Float64)
    # Remove elements from the front if they're out of the window
    while length(q.values) >= q.window
        oldest_value = popfirst!(q.values)
        if oldest_value == first(q.minima)
            popfirst!(q.minima)
        end
        if oldest_value == first(q.maxima)
            popfirst!(q.maxima)
        end
    end

    # Push new value and remove elements that are not candidates
    push!(q.values, value)
    while !isempty(q.minima) && value < last(q.minima)
        pop!(q.minima)
    end
    while !isempty(q.maxima) && value > last(q.maxima)
        pop!(q.maxima)
    end

    push!(q.minima, value)
    push!(q.maxima, value)
end

@doc """
Get the minimum and maximum values in the MovingExtrema2 buffer.
$(TYPEDSIGNATURES)
"""
function Base.extrema(q::MovingExtrema)
    min_val = isempty(q.minima) ? missing : first(q.minima)
    max_val = isempty(q.maxima) ? missing : first(q.maxima)
    return (min_val, max_val)
end
