
@doc "Exchange ohlcv candles limits."
const ohlcv_limits = IdDict(
    :lbank => 2000,
    :poloniex => 20000,
    :kucoin => nothing,
    :binance => 20000,
    :bybit => 20000
)

@doc "Some exchanges are split into different classes in ccxt."
const futures_exchange = IdDict(
    :kucoin => :kucoinfutures
)
