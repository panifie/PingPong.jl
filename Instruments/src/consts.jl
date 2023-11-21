@doc "A list of fiat and fiat-like assets names." # TODO: turn into enum?
const fiatnames = Set([
    "USD",
    "USDT",
    "OUSD",
    "PAX",
    "BUSD",
    "USDC",
    "DAI",
    "EUR",
    "CEUR",
    "USDN",
    "CUSD",
    "SUSD",
    "TUSD",
    "USDJ",
])

@doc "A set of symbols representing fiat and fiat-like assets"
const fiatsyms = Set(Symbol.(fiatnames))

@doc "The default separator used in market symbols"
const DEFAULT_MARKET_SEPARATOR = raw"/"
@doc "A collection of all possible separators used in market symbols"
const ALL_MARKET_SEPARATORS = raw"/\-_."
@doc "The separator used to separate the settlement currency from the quote currency in a market symbol."
const SETTLEMENT_SEPARATOR = raw":"
@doc """[From CCTX](https://docs.ccxt.com/en/latest/manual.html#option)"""
const FULL_SYMBOL_GROUPS_REGEX = Regex(
    "([^$(ALL_MARKET_SEPARATORS)]+)[$(ALL_MARKET_SEPARATORS)]([^:]*):?([^-]*)-?([^-]*)-?([^-]*)-?([^-]*)",
)
