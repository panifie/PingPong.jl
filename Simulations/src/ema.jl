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

function ema(val::T, prev::T; n::Int=6, alpha::T=2.0 / n + 1) where {T<:Real}
    alpha * (val - prev) + prev
end
