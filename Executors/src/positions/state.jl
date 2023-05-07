function hold!(s::IsolatedStrategy, ai::MarginInstance, o::IncreaseOrder)
    push!(s.holdings, ai)
    pos = position(ai, o)
end
hold!(::IsolatedStrategy, _, ::ReduceOrder) = nothing
