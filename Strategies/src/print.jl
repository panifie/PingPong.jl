using Data: closelast
using Instances: pnl, MarginInstance, NoMarginInstance, value

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
        val = value(ai, p, price)
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

trades_total(s::Strategy) = begin
    n_trades = 0
    for ai in s.universe.data.instance
        n_trades += length(ai.history)
    end
    n_trades
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
    write(out, "Name: $(nameof(s))\n")
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
    n_trades = trades_total(s)
    write(out, "Holdings: assets(trades): $(mmh.count)($(n_trades))")
    if mmh.min[1] != cur
        write(out, ", min $(Cash(mmh.min...))($cur)")
    end
    if mmh.max[1] != cur && mmh.max[1] != mmh.min[1]
        write(out, ", max $(Cash(mmh.max...))($cur)\n")
    else
        write(out, "\n")
    end
    write(out, "Pending buys: $(count(s, Buy))\n")
    write(out, "Pending sells: $(count(s, Sell))\n")
    write(out, "$(s.cash) (Cash)\n")
    write(out, "$(current_total(s)) (Total)")
end
