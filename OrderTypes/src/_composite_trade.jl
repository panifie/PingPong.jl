# TYPENUM
@doc "A composite trade groups all the trades belonging to an order request.
- `trades`: the sequence of trades that matched the order.
- `rateavg`: the average price across all trades.
- `feestot`: sum of all fees incurred order trades.
- `amounttot`: sum of all the trades amount (~ Order amount).
"
struct CompositeTrade{O<:Order}
    request::O
    trades::Vector{Trade{O}}
    priceavg::Float64
    feestot::Float64
    amounttot::Float64
end
