@doc "When the candle is _red_, `high` happens before `low`."
ishighfirst(open, close) = close <= open

@doc "Calc the profits given the open and close price, with amounts and fees.

- The `*_price` is the _quote_ price, usually within OHLC boundaries.
"
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

