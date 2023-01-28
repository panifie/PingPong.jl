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

const DEFAULT_MARKET_SEPARATOR = raw"/"
const ALL_MARKET_SEPARATORS = raw"/\-_."
const SETTLEMENT_SEPARATOR = raw":"
@doc """[From CCTX](https://docs.ccxt.com/en/latest/manual.html#option)"""
const FULL_SYMBOL_GROUPS_REGEX = Regex(
    "([^$(ALL_MARKET_SEPARATORS)]+)[$(ALL_MARKET_SEPARATORS)]([^:]*):?([^-]*)-?([^-]*)-?([^-]*)-?([^-]*)",
)
