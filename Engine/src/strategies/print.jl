minmax_holdings(s::Strategy) = begin
    n_holdings = 0
    n_trades = 0
    max_hold = 0.0
    min_hold = Inf
    for ai in s.holdings
        n_holdings += 1
        if ai.cash.value > max_hold
            max_hold = ai.cash
        end
        if 0 < ai.cash.value < min_hold
            min_hold = ai.cash
        end
        n_trades += length(ai.history)
    end
    (min=min_hold, max=max_hold, count=n_holdings, trades=n_trades)
end

function Base.show(out::IO, s::Strategy)
    write(out, "Name: $(nameof(s))\n")
    write(out, "Config: $(s.config.min_amount)(Base Amount), $(s.config.initial_cash)(Initial Cash)\n")
    n_inst = nrow(s.universe.data)
    n_exc = length(unique(s.universe.data.exchange))
    write(out, "Universe: $n_inst instances, $n_exc exchanges")
    write(out, "\n")
    mmh = minmax_holdings(s)
    write(out, "Holdings: assets(trades): $(mmh.count)($(mmh.trades)), min $(mmh.min), max $(mmh.max)\n")
    write(out, "Orders: $(length(s.orders))\n")
    write(out, "$(s.cash) (Cash)\n")
    write(out, "$(current_worth(s)) (Worth)")
end
