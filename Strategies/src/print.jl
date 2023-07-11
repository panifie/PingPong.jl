using Data: closelast
using Instances: pnl, MarginInstance, NoMarginInstance, value
using OrderTypes: LiquidationTrade, LongLiquidationTrade, ShortLiquidationTrade, LongTrade, ShortTrade

_mmh(ai, val, min_hold, max_hold) = begin
    if val > max_hold[2]
        max_hold = (ai.asset.bc, val)
    end
    if 0 < val < min_hold[2]
        min_hold = (ai.asset.bc, val)
    end
    (min_hold, max_hold)
end

function _assetval(ai::MarginInstance, n_holdings, min_hold, max_hold; price)
    for p in (Long(), Short())
        pos = position(ai, p)
        iszero(cash(pos)) && continue
        n_holdings += 1
        val = value(ai, p; current_price=price)
        min_hold, max_hold = _mmh(ai, val, min_hold, max_hold)
    end
    (n_holdings, min_hold, max_hold)
end
function _assetval(ai::NoMarginInstance, n_holdings, min_hold, max_hold; price)
    iszero(cash(ai)) || begin
        n_holdings += 1
        val = cash(ai) * price
        min_hold, max_hold = _mmh(ai, val, min_hold, max_hold)
    end
    (n_holdings, min_hold, max_hold)
end

function minmax_holdings(s::Strategy)
    n_holdings = 0
    max_hold = (nameof(s.cash), 0.0)
    min_hold = (nameof(s.cash), Inf)
    datef = lasttrade_func(s)
    for ai in s.holdings
        iszero(ai) && continue
        price = closeat(ai.ohlcv, datef(ai.ohlcv.timestamp))
        (n_holdings, min_hold, max_hold) = _assetval(
            ai, n_holdings, min_hold, max_hold; price
        )
    end
    (min=min_hold, max=max_hold, count=n_holdings)
end

@doc "All trades recorded in the strategy universe (includes liquidations)."
trades_count(s::Strategy) = begin
    n_trades = 0
    for ai in s.universe
        n_trades += length(ai.history)
    end
    n_trades
end

@doc "All trades in the strategy universe excluding liquidations, returns the tuple `(trades, liquidations)`."
function trades_count(s::Strategy, ::Val{:liquidations})
    trades = 0
    liquidations = 0
    for ai in s.universe
        asset_liquidations = count((x -> x isa LiquidationTrade), ai.history)
        trades += length(ai.history) - asset_liquidations
        liquidations += asset_liquidations
    end
    (; trades, liquidations)
end

function trades_count(s::Strategy, ::Val{:positions})
    long = 0
    short = 0
    liquidations = 0
    for ai in s.universe
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

function Base.show(out::IO, s::Strategy)
    write(out, "Name: $(nameof(s)) ($(typeof(execmode(s))))\n")
    cur = nameof(s.cash)
    write(
        out,
        "Config: $(string(s.margin)), $(s.config.min_size)($cur)(Base Size), $(s.config.initial_cash)($(cur))(Initial Cash)\n",
    )
    n_inst = nrow(s.universe.data)
    n_exc = length(unique(s.universe.data.exchange))
    write(out, "Universe: $n_inst instances, $n_exc exchanges")
    write(out, "\n")
    mmh = minmax_holdings(s)
    long, short, liquidations = trades_count(s, Val(:positions))
    trades = long + short
    write(out, "Trades: $(trades) ~ $long(longs) ~ $short(shorts) ~ $(liquidations)(liquidations)\n")
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
    tot = current_total(s)
    t = nameof(s.cash)
    write(out, "$(t): $(tot) (Total)")
end
