module MarginStrat

using PingPong
@strategyenv!
@contractsenv!

const NAME = :MarginStrat
const EXCID = ExchangeID(:binance)
const S{M} = Strategy{M,NAME,typeof(EXCID),Isolated}
const SC{E,M,R} = Strategy{M,NAME,E,R}
const TF = tf"1d"

# Load required indicators
# using .Indicators
using Indicators: rsi, ema

ping!(_::SC, ::WarmupPeriod) = Day(27 * 2)

function qqe(close)
    rsi(close; n=14) |>
    (x -> ema(x; n=5)) |>
    (x -> abs.(diff(x))) |>
    (x -> ema(x; n=27)) |>
    (x -> ema(x; n=27)) |>
    (x -> x .* 4.236) |>
    (x -> pushfirst!(x, NaN)) # because of `diff`
end

function qqe!(ohlcv, from_date)
    ohlcv = viewfrom(ohlcv, from_date; offset=-27*2)
    # shift by one to avoid lookahead # FIXME: this should not be needed
    [qqe(ohlcv.close);;] # it's a matrix
end

function ping!(s::SC{<:ExchangeID,Sim}, ::ResetStrategy)
    pong!(qqe!, s, InitData(); cols=(:qqe,), timeframe=tf"1d")
    @assert hasproperty(ohlcv(first(s.universe), tf"1d"), :qqe)
end

function handler(s, ai, ats, date)
    # Calculate QQE indicator
    pong!(qqe!, s, ai, UpdateData(); cols=(:qqe,))

    data = ohlcv(ai, tf"1d")
    # Get trend direction
    v = data[ats, :qqe]
    trend = if v > 13.22
        -1
    elseif v <  8.96
        1
    else
        0
    end

    # Get current exposure
    pos = position(ai)
    exposure = pos === nothing ? 0.0 : cash(pos)
    # If the position is short, the value is negative
    @assert iszero(exposure) ||
        islong(pos) && exposure >= 0.0 ||
        isshort(pos) && exposure <= 0.0

    # Define constants
    target_size = ai.limits.cost.min * 10.0

    if trend > 0.0
        # Calculate target position size
        price = closeat(data, ats)
        target_pos = target_size / price

        # Calculate trade amount needed
        amount = target_pos - exposure

        if exposure < 0.0
            # close long position
            pong!(s, ai, Short(), date, PositionClose())
        end

        # This check is not necessary, since the bot
        # validates the inputs. Calling pong! with an amount too low
        # would make the call return `nothing`.
        if amount * price > ai.limits.cost.min
            pong!(s, ai, MarketOrder{Buy}; amount=amount, date)
        end

    elseif trend < 0.0
        # Calculate target position size
        price = closeat(data, ats)
        target_pos = -target_size / price

        # Calculate trade size needed
        amount = target_pos + exposure

        if exposure > 0.0
            # close long position
            pong!(s, ai, Long(), date, PositionClose())
        end

        if amount * price < -ai.limits.cost.min
            # Submit sell order
            pong!(s, ai, ShortMarketOrder{Sell}; amount, date)
        end
    end
end

function ping!(s::SC, ts::DateTime, ctx)
    ats = available(s.timeframe, ts)
    foreach(s.universe) do ai
        handler(s, ai, ats, ts)
    end
end

function ping!(::Type{<:Union{SC,S}}, ::StrategyMarkets)
    ["BTC/USDT:USDT"]
end

end # module
