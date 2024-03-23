using .Data: closelast
using .Instances: pnl, MarginInstance, NoMarginInstance, value, ohlcv
using .OrderTypes:
    LiquidationTrade, LongLiquidationTrade, ShortLiquidationTrade, LongTrade, ShortTrade

@doc """ Updates the minimum and maximum holdings based on the provided value.

$(TYPEDSIGNATURES)

Given an asset instance, a value, and the current minimum and maximum holdings, this function updates the minimum and maximum holdings if the provided value is less than the current minimum or greater than the current maximum. It returns the updated minimum and maximum holdings.
"""
_mmh(ai, val, min_hold, max_hold) = begin
    if val > max_hold[2]
        max_hold = (ai.asset.bc, val)
    end
    if 0 < val < min_hold[2]
        min_hold = (ai.asset.bc, val)
    end
    (min_hold, max_hold)
end

@doc """ Calculates the asset value for both long and short positions.

$(TYPEDSIGNATURES)

This function iterates over both long and short positions. If the asset instance for a position is not zero, it increments the number of holdings and calculates the value of the asset for the position at the current price. It then updates the minimum and maximum holdings using the `_mmh` function. The function returns the updated number of holdings, minimum holdings, and maximum holdings.
"""
function _assetval(ai::MarginInstance, n_holdings, min_hold, max_hold; price)
    for p in (Long(), Short())
        iszero(ai, p) && continue
        n_holdings += 1
        val = value(ai, p; current_price=price)
        min_hold, max_hold = _mmh(ai, val, min_hold, max_hold)
    end
    (n_holdings, min_hold, max_hold)
end
@doc """ Calculates the asset value for a NoMarginInstance.

$(TYPEDSIGNATURES)

This function checks if the cash of the NoMarginInstance is not zero. If it's not, it increments the number of holdings and calculates the value of the asset at the current price. It then updates the minimum and maximum holdings using the `_mmh` function. The function returns the updated number of holdings, minimum holdings, and maximum holdings.
"""
function _assetval(ai::NoMarginInstance, n_holdings, min_hold, max_hold; price)
    iszero(cash(ai)) || begin
        n_holdings += 1
        val = cash(ai) * price
        min_hold, max_hold = _mmh(ai, val, min_hold, max_hold)
    end
    (n_holdings, min_hold, max_hold)
end

@doc """ Calculates the minimum and maximum holdings for a strategy.

$(TYPEDSIGNATURES)

This function iterates over the holdings of a strategy. For each holding, it calculates the current price and updates the number of holdings, minimum holdings, and maximum holdings using the `_assetval` function. The function returns the minimum holdings, maximum holdings, and the count of holdings.
"""
function minmax_holdings(s::Strategy)
    n_holdings = 0
    max_hold = (nameof(s.cash), 0.0)
    min_hold = (nameof(s.cash), Inf)
    datef = lasttrade_func(s)
    for ai in s.holdings
        iszero(ai) && continue
        df = ohlcv(ai)
        price = try
            closeat(df, datef(df.timestamp))
        catch
            close = df.close
            if isempty(close)
                NaN
            else
                last(close)
            end
        end
        (n_holdings, min_hold, max_hold) = _assetval(
            ai, n_holdings, min_hold, max_hold; price
        )
    end
    (min=min_hold, max=max_hold, count=n_holdings)
end

@doc "All trades recorded in the strategy universe (includes liquidations)."
trades_count(s::Strategy) = begin
    n_trades = 0
    for ai in universe(s)
        n_trades += length(ai.history)
    end
    n_trades
end

@doc """ Counts all trades recorded in the strategy universe.

$(TYPEDSIGNATURES)

This function iterates over the universe of a strategy. For each asset instance in the universe, it increments a counter by the length of the asset instance's history. The function returns the total count of trades.
"""
function trades_count(s::Strategy, ::Val{:liquidations})
    trades = 0
    liquidations = 0
    for ai in universe(s)
        asset_liquidations = count((x -> x isa LiquidationTrade), ai.history)
        trades += length(ai.history) - asset_liquidations
        liquidations += asset_liquidations
    end
    (; trades, liquidations)
end

@doc """ Counts the number of long, short, and liquidation trades in the strategy universe.

$(TYPEDSIGNATURES)

This function iterates over the universe of a strategy. For each asset instance in the universe, it counts the number of long trades, short trades, and liquidation trades. The function returns the total count of long trades, short trades, and liquidation trades.
"""
function trades_count(s::Strategy, ::Val{:positions})
    long = 0
    short = 0
    liquidations = 0
    for ai in universe(s)
        long_asset_liquidations = count((x -> x isa LongLiquidationTrade), ai.history)
        short_asset_liquidations = count((x -> x isa ShortLiquidationTrade), ai.history)
        n_longs = count((x -> x isa LongTrade), ai.history)
        n_shorts = count((x -> x isa ShortTrade), ai.history)
        long += n_longs - long_asset_liquidations
        short += n_shorts - short_asset_liquidations
        liquidations += long_asset_liquidations + short_asset_liquidations
    end
    (; long, short, liquidations)
end

orders(s::Strategy, ::Type{Buy}) = s.buyorders
orders(s::Strategy, ::Type{Sell}) = s.sellorders

@doc """ Counts the number of orders for a given order side in a strategy.

$(TYPEDSIGNATURES)

This function iterates over the orders of a given side (Buy or Sell) in a strategy. It increments a counter by the length of the orders. The function returns the total count of orders.
"""
function Base.count(s::Strategy, side::Type{<:OrderSide})
    n = 0
    for ords in values(orders(s, side))
        n += length(ords)
    end
    n
end

_ascash((val, sym)) = Cash(val, sym)

Base.string(::Isolated) = "Isolated Margin"
Base.string(::Cross) = "Cross Margin"
Base.string(::NoMargin) = "No Margin"

@nospecialize
function Base.show(out::IO, s::Strategy; price_func=lasttrade_price_func)
    exc = exchange(s)
    write(out, "Name: $(nameof(s)) ($(s |> execmode |> typeof |> nameof)) ")
    if islive(s)
        if issandbox(exc)
            write(out, "[Sandbox]")
        else
            write(out, "[Wallet!]")
        end
    end
    let t = attr(s, :run_task, nothing)
        if !(isnothing(t)) && !istaskdone(t) && istaskstarted(t)
            write(out, "(Running)")
        end
    end
    cur = nameof(s.cash)
    write(
        out,
        "\nConfig: $(string(s.margin)), $(s.config.min_size)($cur)(Base Size), $(s.config.initial_cash)($(cur))(Initial Cash)\n",
    )
    n_inst = nrow(universe(s).data)
    n_exc = length(unique(universe(s).data.exchange))
    write(out, "Universe: $n_inst instances, $n_exc exchanges")
    write(out, "\n")
    mmh = minmax_holdings(s)
    long, short, liquidations = trades_count(s, Val(:positions))
    trades = long + short
    write(
        out,
        "Trades: $(trades) ~ $long(longs) ~ $short(shorts) ~ $(liquidations)(liquidations)\n",
    )
    write(out, "Holdings: $(mmh.count)")
    if mmh.min[1] != cur
        write(out, " ~ min $(Cash(mmh.min...))($cur)")
    end
    if mmh.max[1] != cur && mmh.max[1] != mmh.min[1]
        write(out, " ~ max $(Cash(mmh.max...))($cur)\n")
    else
        write(out, "\n")
    end
    write(out, "Pending buys: $(count(s, Buy))\n")
    write(out, "Pending sells: $(count(s, Sell))\n")
    write(out, "$(s.cash) (Cash)\n")
    tot = current_total(s; price_func, local_bal=true)
    t = nameof(s.cash)
    write(out, "$(t): $(tot) (Total)")
end
@specialize
