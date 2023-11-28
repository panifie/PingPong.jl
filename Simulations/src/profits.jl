@doc "When the candle is _red_, `high` happens before `low`."
ishighfirst(open, close) = close <= open

@doc """
Calculate the profits given open and close prices, taking account of amounts and fees.

$(TYPEDSIGNATURES)

Initial shares are calculated as `1.0 / open_price`.
The trade's worth at open and close is then calculated using these shares.
Cost accounts for the trade's worth at open and the fee, while cash represents what's returned after subtracting fees from the worth at close.
Profit is then computed as the ratio of cash to cost, minus 1.
The result is rounded to `digits` decimal places.

Note:
- `*_price` represents the _quote_ price, which is usually within OHLC boundaries.
"""
function profitat(open_price::Real, close_price, fee; digits=8)
    shares = 1.0 / open_price
    # How much the trade is worth at open
    size_open = shares * open_price
    # How much the trade is worth at close
    size_close = shares * close_price
    # How much was spent opening the trade with fees
    cost = size_open + size_open * fee
    # How much was returned, minus fees
    cash = size_close - size_close * fee
    profits = cash / cost - 1.0
    round(profits; digits)
end

