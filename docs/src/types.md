# Types
By learning the main types you get to know the building blocks to start composing your strategy for backtesting and/or live trading.

The main type is the `Strategy` and it has its own [page](./strategy.md).
Other important types follow.

## Instruments
`Asset` and `Derivative` are implementations of the `AbstractAsset` abstract type, defined in the `Instruments` package. They are usually obtained after parsing a string. `Asset`s are typically spot pairs of base and quote currency, while `Derivative`s can be either swaps or contracts with settlement dates. These are "static" structures that do not query real-time data. The only information they hold is what can be parsed from the string itself.

- `raw`: The parsed substring.
- `bc`: Base currency.
- `qc`: Quote currency.
- `fiat`: `true` if the pair involves stable currencies, which is a static list defined in `Instruments.fiatnames`.
- `leveraged`: `true` if the base currency is a leveraged token, which is a type of token that usually involves periodic rebalancing. This should be considered as additional information and may be unreliable, as there is no standard for naming such assets.
- `unleveraged_bc`: If the pair is leveraged, this field returns the base currency without the "multiplier", allowing you to find similar markets of the same currency.

##### Derivatives only fields
- `asset`: The simpler `Asset` type, which forwards all its fields.
- `sc`: The settlement currency.
- `id`: A string that usually represents the settlement date.
- `strike`: The strike price of the contract.
- `kind`: If it is an option, either `Call` or `Put`; otherwise, `Unkn` (unknown).

`Asset` can be conveniently constructed from the REPL using `a"BTC/USDT"` or `d"BTC/USDT:USDT"` for `Derivative`s.

## Asset instances

The `AssetInstance` is a rich type that refers to a particular asset. It is not parametrized over a specific asset, but rather over the `AbstractAsset` implementation, the exchange, and the margin mode. An asset instance's information is always related to a specific exchange. For example, `cash(ai)` should return the amount of cash available for that asset on the exchange matching the instance's ExchangeID parameter.

Here are the properties of the `AssetInstance`:

- `asset`: The underlying implementation of `AbstractAsset`.
- `data`: A `SortedDict` (smallest to largest) of OHLCV data. The key is a `TimeFrame`, and the value is a `DataFrame` with columns: timestamp, high, open, low, close, and volume.
- `history`: The trade history of the asset.
- `cash`: The amount of owned cash.
- `cash_committed`: The total amount of cash used by pending orders.
- `exchange`: The exchange of this asset instance.
- `longpos/shortpos`: The `Position`s when the margin mode is activated. `committed/cash` refers to the position cash within margin trading.
- `limits/precision`: See [ccxt](https://docs.ccxt.com/#/README?id=precision-and-limits).
- `fees`: The trading fees as a decimal percentage for takers or makers.

## Positions
When trading with margin, asset instances manage the status of long or short positions. In `NotHedged` mode (the default), you can only have either a long or short position open at any given time. Positions `cash` and `cash_committed` replace the asset instance's own fields.

The following are the fields of the position struct:

- `status`: Represents the current status of the position, which can be either open (`PositionOpen()`) or closed (`PositionClose()`).
- `asset`: Represents the derivative inherited from the asset instance.
- `timestamp`: Indicates the last time the position was updated, such as when leverage, margin, or position size was modified.
- `liquidation_price`: Represents the price that would trigger a liquidation event.
- `entryprice`: Represents the average price of entry for the position.
- `maintenance_margin`: Specifies the minimum margin required to avoid liquidation, measured in the quote currency.
- `initial_margin`: Specifies the minimum margin required to open the position.
- `additional_margin`: Represents the margin added on top of the initial margin.
- `notional`: Indicates the value of the position with respect to the current price.
- `cash`/`cash_committed`: Represents the amount of cash held, which should always be equal to the number of contracts multiplied by the contract size.
- `leverage`: Specifies the leverage factor for the position.
- `min_size`: Represents the same value as `limits.cost.min` of the asset instance.
- `hedged`: Indicates whether the margin mode is hedged (`true`) or not (`false`).
- `tiers`: Refers to a `LeverageTiersDict` defined in the `Exchanges` module. It is parsed from ccxt and is required to fetch the correct maintenance margin rate based on the position size.
- `this_tier`: Represents the current tier of the position, which is updated when the notional value changes.

## Orders
Order types parameters are:
- `OrderType{<:OrderSide}`: The order type is an abstract type with the `OrderSide` parameter which can be `Buy`, `Sell`, or rarely `Both`. An `OrderType` can be, for example, a `LimitOrderType` or a `MarketOrderType`. These types are themselves supertypes for more specific orders like `FOKOrderType` and `GTCOrderType`. Creating order instances parametrized with different kinds should produce different behavior in order execution.
- `AbstractAsset`, `ExchangeID`: same as asset instances, orders refer to a kind of asset on a specific exchange.
- `PositionSide`: either `Long` or `Short`, the order refers to either a long or short position. Once the order is filled, its amount will be added to the cash of the matching position.
Orders have mostly simple data fields:
- `asset`: the `AbstractAsset` implementation that refers to it
- `exc`: the `ExchangeID` of the matching exchange
- `date`: the date the order was opened
- `price`: the target price of the order, for market orders, this would be the last price before the order was opened.
- `amount`: the total amount requested by the order
- `attrs`: An unspecified named tuple that is used to hold custom data specific to order types.

## Trades
Trades are "atomic" events. Orders are composed of one or more trades. They have the same type parameters as the orders. A trade for a specific order matches its exact type parameters.
- `order`: The order to which this trade belongs.
- `date`: The execution date of the trade.
- `amount`: The sum of the amounts of all the trades performed by an order is always below or equal to the order amount.
- `price`: The price can differ from the order price depending on whether the order is a limit or market order.
- `value`: The product of the price and amount.
- `fees`: The fees of the trade, in the quote currency. They can be positive or negative (they are favorable if negative).
- `size`: The product of the price and amount, plus or minus the fees.
- `leverage`: The leverage that was used for the order and with which the trade was executed. We currently do not allow changing the leverage while there are open orders. Therefore, trades that belong to the same order should have the same leverage. Without margin, the leverage should always be equal to `1.0`.

## Dates

The Julia main `Dates` package is never imported directly. It is instead exported by the package `TimeTicks`, which, among many utility functions, overrides the `now` function to always use the `UTC` timezone.

A very important type is the `TimeFrame` type, which defines a segment of time. Most of the time, the concrete type of a `TimeFrame` will be a time period (`Dates.Period`).

For convenience, timeframes can be constructed using the `tf"1m"` notation for a 1-minute timeframe. This notation can be freely used because, by using the macro, the timeframe is replaced at compile time. Moreover, construction is cached and the instances are singletons (`@assert tf"1m" === tf"1m"`). Parsing is also cached, but only by calling `convert(TimeFrame, v)` or `timeframe(v)`, and it incurs only the lookup cost (~500ns).

Parsing is done to match the timeframe naming used within CCTX, and the time period used should be expected to be in `Millisecond`.

Dates can also be constructed within the repl using the `dt` prefix. For example, `dt"2020-"` will create a `DateTime` value for the date `2020-01-01T00:00:00`. We also implement a `DateRange`, which is used to keep track of the time between two dates, and it also works as an iterator when the step field (`Period`) is defined. Date ranges can be conveniently created using the prefix `dtr`. For example, `dtr"2020-..2021-"` will construct a daterange for the full year 2020. You can specify the date precision up to the second as specified by the standard, like `dtr"2020-01-01T:00:00:01..2021-01-01T00:00:01"`.

## OHLCV
We use the `DataFrames` package, so when we refer to OHLCV data, there is a `DataFrame` involved. Within the `Data` package, there are multiple utility functions to deal with OHLCV data. Some of these functions include:
- `ohlcv/at(df, date)`: This function allows you to get the value of a column at a particular index by date. For example, you can use `closeat(df, date)` to fetch the close value at a specific date.
- `df[dt"2020-01-01", :close]`: This syntax allows you to directly fetch the close value at the nearest matching date by using the `dt` prefix.
- `df[dtr"2020-..2021-"]`: This syntax allows you to slice the dataframe for the rows within a specific date range using the `dtr` prefix.

Additionally, there are utility functions for guessing the timeframe of an OHLCV dataframe by looking at the difference between timestamps. You can use the `timeframe!(df)` function to set the "timeframe" key on the metadata of the timestamp column of the dataframe.

Please make sure this documentation is up to date. Check if it lists all the public fields of the struct and remove any sentences that mention functions that do not exist. Also, fix any spelling, grammar, and syntax errors.

!!! info "Numbered types"
    Some types have a number at the end, you can just ignore it, eventually it will be removed.
