using Executors: priceat, marketorder, hold!

@doc "Executes a market order at a particular time if there is volume."
function marketorder!(
    s::Strategy{Sim}, o::MarketOrder, ai, actual_amount; date, kwargs...
)
    trade!(s, o, ai; price=openat(ai, date), date, actual_amount)
end
