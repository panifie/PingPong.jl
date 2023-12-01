- **asset**: An asset refers to a structure created from parsing a symbol. It typically represents an `Asset`, `Derivative`, or `AssetInstance`. Variables representing asset instances are often named `ai`, while simple assets are named `a` or `aa` (for `AbstractAsset`).

- **sym**: Though `Symbol` is a built-in type in Julia, in a trading context "symbol" often denotes the pairing of a base currency with a quote currency. There is no strict rule for the usage of `sym`, but it commonly refers to a `Symbol` for single currencies and a `String` for currency pairs.

- **pair**: A pair is usually a `String` in the format `"$BASE/$QUOTE"` where the slash separates the base and the quote currencies.

- **bc, qc**: These abbreviations stand for base currency (`bc`) and quote currency (`qc`). They are `Symbol` types and correspond to the fields of an `AbstractAsset`.

- **futures/swap/perps**: While swaps are a type of futures contract, they are specifically "perpetual futures" and are thus referred to distinctly. Following the CCXT library's conventions, swaps have symbols formatted as `"$BASE/$QUOTE:$SETTLE"`. Plain future contracts include an expiry date, denoted as `"$BASE/$QUOTE:$SETTLE-$EXPIRY"`.

- **amount**: The term "amount" generally refers to the quantity of the base currency. For example, if you purchase 100 USD worth of BTC at a price of 1000 USD per BTC, the amount is `100 / 1000 = 0.1 BTC`.

- **price**: The price always refers to the cost of the base currency quoted in the quote currency. For instance, if the price of BTC is 1000 USD, it means `1 BTC = 1000 USD`.

- **size**: Size typically indicates the quantity of quote currency used to execute a trade, inclusive of fees.

- **long/short**: These terms are exclusively used in the context of margin trading. "Long" indicates a position betting on an increase in an asset's price, while "short" refers to a position betting on a decrease.

- **ohlc/v**: This abbreviation stands for Open, High, Low, Close, and Volume, and it usually refers to a dataframe containing this market data.

- **pairdata**: This term describes a complex data structure that associates a dataframe, a Zarr array, and a trading pair.

- **exc/exchange**: This can refer to an `Exchange` instance, an `ExchangeID`, or merely the `Symbol` of an exchange ID. For convenience, a global `exc` variable is defined in the `ExchangeTypes` module for use in the REPL.

- **sandbox**: Many exchanges offer a "testnet" to trial API endpoints. Note that this is distinct from paper trading and should not be confused with it.

- **instance**: This term typically implies an `AssetInstance`.

- **candle**: A candle can be a row from an OHLCV dataframe, a named tuple, or an actual `Candle` structure.

- **resample**: Resampling usually implies downsampling, as upsampling is seldom beneficial.

- **side/position**: The word "side" refers to either a "buy" or "sell" action. In contrast, when discussing the "side of a position," such as "long" or "short," the term "position" is used instead. Thus, a trade's side is either "buy" or "sell," while its position is "long" or "short."