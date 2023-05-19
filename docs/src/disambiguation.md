There may be many terms used through out the code base that can semantically mean the same thing, so it can be confusing when trying to understand what a function does, here is a list to should clear up at least some of them:

- asset: an asset is a structure constructed from parsing a symbol, usually we mean either an simple `Asset` or a `Derivative` or an `AssetInstance`. Many times asset instances variables are named `ai`, and plain assets either `a` or `aa` (`AbstractAsset`).
- sym: In julia `Symbol` is a built in type, but many times in trading context a "symbol" represents an association between a base currency and a quote currency. There isn't a clear distinction here about when we call things as `sym`. But most of the times it is either a `Symbol` if it is only a currency or a `String` if it is a pair.
- pair: it is most of the times a `String` (or a `SubString`) of the form "\$BASE/\$QUOTE" (note the slash in-between).
- bc,qc: variables that have this name are base or quote currency symbols, like the ones accessed as fields of an `AbstractAsset`, and they are indeed of type `Symbol`.
- futures/swap/perps: swaps are futures, but they are a kind of "perpetual futures" so they have distinct naming.
  Following ccxt conventions, if its a swap the raw symbol is of the form "\$BASE/\$QUOTE:\$SETTLE", if it is a plain "future" contract then it will have an expiry date attached like "\$BASE/\$QUOTE:\$SETTLE-$EXPIRY"
- amount: when we talk about amounts, we usually mean the quantity in _base_ currency. If we buy 100\$ worth of BTC priced at 1000$, then our amount will be 100/1000 == 0.1BTC
- price: it is always the _quotation_ of the base currency. BTC price is 1000$ if `1BTC / 1$ == 1000`
- size: it is most of the times the quantity in quote currency spent to execute a trade, it *includes* fees.
- long/short: long and short are terms only used in the context of margin trading.
- ohlc/v: usually a dataframe of ohlcv data
- pairdata: a "lower" kind of data structure that represents an association between a dataframe, a zarr array, and a pair.
- exc/exchange: either an `Exchange` instance, or an `ExchangeID`, or just the `Symbol` of an exchange id. There is a global `exc` variable in the `ExchangeTypes` module that is defined for convenience when working in the repl.
- sandbox: many exchanges provide a "testnet" to test api endpoints, be ware that it has nothing to do with paper trading.
- instance: most of the times it means an _asset_ instance (`AssetInstance`).
- candle: it is either a dataframe row (from an ohlcv dataframe) or a named tuple, or an actual `Candle` struct.
- resample: when we resample we usually mean _down sampling_ since up sampling is rarely useful.
- side/position: when we use the word side we usually mean either buy or sell. When instead we mean the "side of a position", long or short we just use the word position. The side of a trade is either buy or sell, the position of a trade is either long or short.
