import Data: candleat, openat, highat, lowat, closeat, volumeat, closelast
using Instruments

function candleat(ai::AssetInstance, date, tf; kwargs...)
    candleat(ai.data[tf], date; kwargs...)
end

function candleat(s::Strategy, ai::AssetInstance, date; tf=s.timeframe, kwargs...)
    candleat(ai, date, tf; kwargs...)
end

macro define_candle_func(fname)
    fname = esc(Symbol(eval(fname)))
    ex1 = quote
        function func(ai::AssetInstance, date; kwargs...)
            func(ai.ohlcv, date; kwargs...)
        end
    end
    ex1.args[2].args[1].args[1] = fname
    ex1.args[2].args[2].args[3].args[1] = fname
    ex2 = quote
        function func(s::Strategy, ai::AssetInstance, date; tf=s.timeframe, kwargs...)
            func(ai.data[tf], date; kwargs...)
        end
    end
    ex2.args[2].args[1].args[1] = fname
    ex2.args[2].args[2].args[3].args[1] = fname
    quote
        $ex1
        $ex2
    end
end
for sym in (openat, highat, lowat, closeat, volumeat)
    @eval @define_candle_func $sym
end

current_worth(s::Strategy) = begin
    worth = Cash(s.cash, 0.0)
    for ai in s.holdings
        add!(worth, ai.cash * closelast(ai.ohlcv))
        add!(worth, ai.cash_committed * closelast(ai.ohlcv))
    end
    add!(worth, s.cash)
    add!(worth, s.cash_committed)
    worth
end

@doc "Returns the first and last trade of any asset in the strategy universe."
function tradesedge(s::Strategy)
    first_trade = nothing
    last_trade = nothing
    for ai in s.universe
        isempty(ai.history) && continue
        this_trade = first(ai.history)
        if isnothing(first_trade) || this_trade.date < first_trade.date
            first_trade = this_trade
        end
        this_trade = last(ai.history)
        if isnothing(last_trade) || this_trade.date > last_trade.date
            last_trade = this_trade
        end
    end
    first_trade, last_trade
end

function trades_profit_history(s::Strategy)
    profits_history = Dict()
    cash = Dict()
    spent = Dict()
    values = Dict()
    final = Dict()
    for ai in s.universe
        a = ai.asset
        cash[a] = 0.0
        spent[a] = 0.0
        values[a] = Float64[]
        profits_history[a] = Float64[]
        for trade in ai.history
            if trade isa BuyTrade
                cash[a] += trade.amount
                spent[a] += trade.size
            else
                cash[a] -= trade.amount
                gross_size = trade.size + trade.size * ai.fees
                price_at_trade = gross_size / trade.amount
                vals = values[a]
                push!(vals, price_at_trade * cash[a])
                length(vals) > 1 &&
                    push!(profits_history[a], (1.0 - vals[end] / vals[end - 1]))
            end
        end
    end
    for (a, profits) in profits_history
        final[a] = sum(profits)
    end
    profits_history, final
end
