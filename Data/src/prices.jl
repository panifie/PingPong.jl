module Prices
using Data.DataFrames

const pranges_futures = (0.98, 0.985, 1.015, 1.02, 1.025)
const pranges_bal = (0.94, 0.95, 0.955, 1.045, 1.05, 1.06)
const pranges_tight = (0.94, 0.98, 0.985, 1.015, 1.02, 1.06)
const pranges_expa = (0.7, 0.8, 0.9, 0.98, 0.985, 1.015, 1.02, 1.1, 1.2, 1.3)

@doc """Given a price, output price at given ratios.
(Predefined ratios - :bal,:futures,:tight,:expa)
"""
function price_ranges(price::Number, ranges=:expa)
    if ranges === :bal
        p = pranges_bal
    elseif ranges === :futures
        p = pranges_futures
    elseif ranges === :tight
        p = pranges_tight
    elseif ranges === :expa
        p = pranges_expa
    else
        p = ranges
    end
    DataFrame(Dict(:price => price, [Symbol(r) => price * r for r in p]...))
    # (price, -price * ranges[1], -price * ranges[2], -price * ranges[3], price * ranges[4])
end

@doc "Get the price range of a map of pairs, using the last available close price."
function price_ranges(mrkts::AbstractDict, args...; kwargs...)
    r = []
    for p in values(mrkts)
        push!(r, (p.name, price_ranges(p.data.close[end], args...; kwargs...)))
    end
    r
end

function price_ranges(pass::AbstractVector, mrkts::AbstractDict; kwargs...)
    r = []
    for (name, _) in pass
        push!(r, (name, price_ranges(mrkts[name].data.close[end]; kwargs...)))
    end
    r
end

@doc "Total profit of a ladder of trades"
function gprofit(peak=0.2, grids=10)
    sum(collect((peak / grids):(peak / grids):peak) .* inv(grids))
end

end
