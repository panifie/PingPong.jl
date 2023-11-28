@doc """ Find the index of the first valid real number in an array

$(TYPEDSIGNATURES)

This function returns the index of the first valid real number in an array. 
If there are no valid real numbers in the array, it returns 0.

"""
function first_valid(x::Array{<:Real})::Int
    if !isnan(x[1])
        return 1
    else
        @inbounds for i in 2:length(x)
            if !isnan(x[i])
                return i
            end
        end
    end
    return 0
end
@doc """ Compute the exponential moving average (EMA) 

$(TYPEDSIGNATURES)

This function calculates the exponential moving average (EMA) for a vector of real numbers. The EMA is a type of weighted moving average that gives more importance to the latest data.
The number of periods `n` and the smoothing factor `alpha` can be specified. 
By default, `n` is set to 6 and `alpha` is set to 2.0 / 7.0.

"""
@views function ema(x::Vector{<:Real}; n::Int=6, alpha::Real=2.0 / 7.0)
    @assert n < size(x, 1) && n > 0 "Argument n out of bounds."
    out = zeros(size(x))
    i = first_valid(x)
    i = 2n
    out[1:(n + i - 2)] .= NaN
    out[n + i - 1] = mean(x[i:(n + i - 1)])
    @inbounds for i in (n + i):size(x, 1)
        out[i] = ema(x[i], out[i - 1]; n, alpha)
    end
    return out
end

@doc """ Compute the exponential moving average (EMA) for a new value 

$(TYPEDSIGNATURES)

This function calculates the exponential moving average (EMA) for a new value, given the previous EMA value.
The EMA is a type of moving average that places a greater weight on the most recent data.
The number of periods `n` and the smoothing factor `alpha` can be specified. 
By default, `n` is set to 6 and `alpha` is set to 2.0 / (n + 1).

"""
function ema(val::T, prev::T; n::Int=6, alpha::T=2.0 / n + 1) where {T<:Real}
    alpha * (val - prev) + prev
end
