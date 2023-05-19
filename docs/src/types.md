# Types
By learning the main types you get to know the building blocks to start composing your strategy for backtesting and/or live trading.

!!! info "Numbered types"
    Some types have a number at the end, you can just ignore it, eventually it will be removed.
    
The main type is the `Strategy` and it has its own [page](./strategy.md).
Other important types follow.

## Instruments
`Asset` and `Derivative` are implementations of the `AbstractAsset` abstract type, defined in the `Instruments` package. They are what we get usually after parsing a string. `Asset`s are most of the time a _spot_ pair of base and quote currency. A `Derivative` is instead either a _swap_ or a contract with a settlment date. These are "static" kind of structures that don't query real time data. The only information they hold is what can be parsed by the string itself.
- `raw`: The substring that was parsed.
- `bc`: base currency
- `qc`: quote currency
- `fiat`: `true` if the pair involves to "stable" currencies, which is a static list defined in `Instruments.fiatnames`
- `leveraged`: `true` if the base currency is a _leveraged_ token, which is a kind of token that usually involves periodic rebalancing. This should be considered only as additional info, and unreliable, since there isn't a standard for naming such assets.
- `unleveraged_bc`: if the pair is leveraged, this should return the base currency without the "multiplier", such that you can use it to find similar markets of the same currency.
### Derivatives only fields
- `asset`: the simpler `Asset` type which forwards all its fields.
- `sc`: the settlement currency
- `id`: a string, usually representing the settlement date
- `strike`: strike price of the contract
- `kind`: if its an option, either `Call` or `Put`, otherwise `Unkn` (unknown)

`Asset` can be conveniently constructed from the REPL using `a"BTC/USDT"` or `d"BTC/USDT:USDT"` for `Derivative`s.

## Asset instances

The `AssetInstance` is the richer type that refers to a particular asset, they are _not_ parametrized over a particular asset (as that would cause "type explosion") but only over the `AbstractAsset` implementation, the exchange and the margin mode. An asset instance information is therefore always related to a specific exchange, `cash(ai)` for example should return how much cash is available for that asset on the exchange matching the instance ExchangeID parameter.
- `asset`: The underlying implementaion of `AbstractAsset`
- `data`: a `SortedDict` (smallest to largest) of ohlcv data. The key is is a `TimeFrame`, the value is a `DataFrame` with columns timestamp,high,open,low,close,volume.
- `history`: the trades history of the asset
- `logs`: `AssetEvents` like leverage updates in case of assets with active margin.
- `cash`: owned cash
- `cash_committed`: total cash used by pending orders
- `exchange`: the exchange of this asset instance
- `longpos/shortpos` the `Position`s when margin mode is activate. `committed/cash` refers to the position cash within margin trading.
- `limits/precision`: see [ccxt](https://docs.ccxt.com/#/README?id=precision-and-limits)
- `fees`: the fees in decimal percentage for trading for taker or maker.

## Positions
When trading with margin, asset instances state manage the status of long or short positions. In `NotHedged` mode (the default) you can only have either a long or short position open at any given time. Positions `cash` and `cash_committed` replace the asset instance own fields.
- `status`: If the position is either open `PositionOpen()` or close `PositionClose()`.
- `asset`: `Derivative` inherited from the asset instance
- `timestamp`: the last time the position was updated either by updating leverage, adding margin or increasing the position.
- `liquidation_price`: the price that would trigger a liquidation event
- `entryprice`: the average price of entry of the position
- `maintenance_margin`: the minimum margin required to avoid liquidation (in quote currency)
- `initial_margin`: the minimum margin required to open the position
- `additional_margin`: margin added on top of the initial margin
- `notional`: the value of the position w.r.t. the current price
- `cash/cash_committed`: the amount held, should always be equal to number of contracts multiplied by the contract size.
- `leverage`: the leverage factor
- `min_size`: same as `limits.cost.min` of the asset instance
- `hedged`: `true` if margin mode is hedged.
- `tiers`: it is a `LeverageTiersDict` defined in the `Exchanges` module. It is parsed from ccxt, it is required to fetch the correct maintenance margin rate w.r.t. the position size.
- `this_tier`: the current tier of the position, updated when the notional value changes.

## Orders
Orders types parameters are:
- `OrderType{<:OrderSide}`: The order type is an abstract type with the `OrderSide` parameter which is `Buy`, `Sell`, and rarely `Both`. An `OrderType` can be for example a `LimitOrderType` or a `MarketOrderType`. These types are themselves supertypes for more specific orders like `FOKOrderType` and `GTCOrderType`. Creating order instances parametrized with different kinds should produce different behaviour in order execution.
- `AbstractAsset`, `ExchangeID`: same as asset instances, orders refer to a kind of asset on a specific exchange.
- `PositionSide`: either `Long` or `Short`, the order refer to either a long or short position. Once the order is filled, it's amount will be added to the cash of the matching position.
Orders have mostly simple data fields:
- `asset`: the `AbstractAsset` implementation that refers to it
- `exc`: the `ExchangeID` of the matching exchange
- `date`: the date the order was opened
- `price`: the target price of the order, for market orders this would be the last price before the order was opened.
- `amount`: the total amount requested by the order
- `attrs`: A unspecified named tuple that is used to hold custom data specific to order types.

## Trades
Trades are "atomic" events, orders are composed of one or more trades. They have the same type parameters as the orders, a trade for a specific order matches its exact type parameters.
- `order`: the order to which this trade belongs to
- `date`: execution date of the trade
- `amount`: The sum of the amounts of all the trades performed by an order is always below or equal the order amount.
- `price`: the price can differ from the order price depending on wheter the order is a limit or market order.
- `value`: `price * amount`
- `fees`: the fees of the trade, in quote currency, they can be positive or negative (they are favorable if negative)
- `size`: `price * amount +/- fees`
- `leverage`: the leverage that was used for the order and which the trade was executed with. We currently don't allow to change the leverage while there are open orders, therefore trades that belong to the same order should have the same leverage. Without margin the leverage should be always equal to `1.0`.

## Dates
The julia main `Dates` package is never imported directly. It is instead exported by the package `TimeTicks` which among many utility functions overrides the `now` function to always use the `UTC` timezone.
A very important type is the `TimeFrame` type which defines a segment of time, most of the times the _concrete_ type of a `TimeFrame` will be a time period (`Dates.Period`).
For convenience timeframes can be constructed like `tf"1m"` for a 1 minute timeframe. This notation can be freely used as you like because by using the macro, the timeframe is replaced at compiled time, moreover construction is cached and the instances are singletons (`@assert tf"1m" === tf"1m"`). Parsing is also cached but only by calling `convert(TimeFrame, v)` or `timeframe(v)` and spend only the lookup cost (`~500ns`).
The parsing is done to matching timeframe naming used within CCTX, and the timeperiod use should be expect to be in `Millisecond`.
Dates can also be constructed within the repl using the dt prefix like `dt"2020-"` will create a `DateTime` value for the date `2020-01-01T00:00:00`. We also implement a `DateRange` which is used to keep track of the time between two dates, and it also works as an iterator when the step field (`Period`) is defined. Date ranges can be conveniently created using the prefix dtr like `dtr"2020-..2021-" will construct a daterange for the full year 2020. You can specify the date precision up to the second as specified by the standard like `dtr"2020-01-01T:00:00:01..2021-01-01T00:00:01"

## OHLCV
We use the `DataFrames` package, so when we refer to ohlcv data there is a `DataFrame` involved. Within the `Data` package there multiple utility functions to deal with ohlcv data, like `ohlcv/at(df, date)` to get the value of a column at a particular index by date, for example `closeat(df, date)`. We implemented date indexing for dataframes so you can also directly call `df[dt"2020-01-01", :close]` to fetch the close value at the nearest matching date, or use a `DateRange` to slice the dataframe for the rows within the daterange time span (`df[dtr"2020-..2021-"]`). There are utility functions for _guessing_ the timeframe of ohlcv data frame by looking at the difference between timestamps, calling `timeframe!(df)` will set the "timeframe" key on the metadata of the _timestamp_ column of the dataframe.
