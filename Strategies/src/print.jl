using Data: closelast

function minmax_holdings(s::Strategy)
    n_holdings = 0
    max_hold = (nameof(s.cash), 0.0)
    min_hold = (nameof(s.cash), Inf)
    datef = lasttrade_func(s)
    for ai in s.holdings
        for pos in (Long(), Short())
            val = abs(cash(ai, pos)) * closeat(ai.ohlcv, datef(ai.ohlcv.timestamp))
            isapprox(val, 0.0; atol=1e-12) && continue
            n_holdings += 1
            if val > max_hold[2]
                max_hold = (ai.asset.bc, val)
            end
            if 0 < val < min_hold[2]
                min_hold = (ai.asset.bc, val)
            end
        end
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
