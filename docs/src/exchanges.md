# Exchanges

Every trade, order, asset instance, and strategy is parameterized against an `ExchangeID`, which is a type constructed from the name (`Symbol`) of an exchange. Currently, the bot supports CCXT with exchanges subtypes of `CcxtExchange`.

There is only one exchange instance (one sandbox and one non-sandbox) constructed per exchange, so calling [`PingPong.Engine.Exchanges.getexchange!`](@ref) will always return the same object for each exchange. The sandbox instance is generally a test-net with synthetic markets.

We try to parse as much info from the (CCXT) exchange such that we can fill attributes such as:
- Markets
- Timeframes
- Asset trading fees, limits, precision
- Funding rates

The support for exchanges is a best-effort basis. To overview if the exchange is likely compatible with the bot, call `check`:

``` julia
using PingPong
@environment!
e = getexchange!(:bybit)
exs.check(e, type=:basic) # for backtesting and paper trading
exs.check(e, type=:live) # for live support
```

The bot tries to use the WebSocket API if available, otherwise, it falls back to the basic REST API. The API keys are read from a file in the `user/` directory named after the exchange name like `user/bybit.json` for the Bybit exchange or `user/bybit_sandbox.json` for the respective sandbox API keys. The JSON file has to contain the fields `apiKey`, `secret`, and `password`.

The strategy quote currency and each asset currency is a subtype of [`PingPong.Engine.Exchanges.CurrencyCash`](@ref), which is a `Number` where operations respect the precision defined by the exchange.

Some commonly fetched information is cached with a TTL, like tickers, markets, and balances.

## Exchange Types
Basic exchange types, and global exchange vars.

```@autodocs; canonical=false
Modules = [PingPong.Exchanges.ExchangeTypes]
```

## Construct and query exchanges

Helper module for downloading data off exchanges.
```@autodocs; canonical=false
Modules = [PingPong.Engine.Exchanges]
Pages = ["exchanges.jl", "tickers.jl", "-data.jl"]
```

## Fetching data from exchanges

Helper module for downloading data off exchanges.
```@autodocs; canonical=false
Modules = [Fetch]
```

[1]: It is possible that in the future the bot will work with the hummingbot gateway for DEX support, and at least another exchange type natively implemented (from panifie).
