@doc """The strategy is the core type of the framework.
- buyfn: (Cursor, Data) -> Order
- sellfn: Same as buyfn but for selling
- base_amount: The minimum size of an order
"""
struct Strategy
    buyfn::Function
    sellfn::Function
    portfolio::Portfolio
    base_amount::Float64
end
