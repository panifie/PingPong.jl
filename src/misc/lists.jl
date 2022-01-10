@doc "A list of fiat and fiat-like assets names."
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
    "USDN"
])

@doc "Mapping of timeframes to default window sizes."
const tf_win = Dict(
    "1m"   =>  20,  #  20m
    "5m"   =>  12,  #  1h
    "15m"  =>  16,  #  4h
    "30m"  =>  16,  #  8h
    "1h"   =>  24,  #  24h
    "2h"   =>  24,  #  48h
    "4h"   =>  42,  #  1w
    "8h"   =>  42,  #  2w
    "1d"   =>  26   #  4w
)

@doc "Reverse mapping of timedeltas (milliseconds) to timeframes."
const td_tf = Dict(
    60000 => "1m",
    300000 => "5m",
    900000 => "15m",
    1800000 => "30m",
    3600000 => "1h",
    7200000 => "2h",
    14400000 => "4h",
    28800000 => "8h",
    86400000 => "1d"
)
