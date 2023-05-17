import Data: candleat, openat, highat, lowat, closeat, volumeat, closelast
using Instances: pnl, position, margin
using Instruments
using Instruments: @importcash!
@importcash!

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

function current_total(s::NoMarginStrategy)
    worth = Cash(s.cash, 0.0)
    for ai in s.holdings
        price = closeat(ai, lasttrade_date(ai))
        add!(worth, ai.cash * price)
        add!(worth, ai.cash_committed * price)
    end
    add!(worth, s.cash)
    add!(worth, s.cash_committed)
    worth
end

function current_total(s::MarginStrategy)
    worth = CurrencyCash(s.cash, 0.0)
    for ai in s.holdings
        for p in (Long, Short)
            price = closeat(ai, lasttrade_date(ai))
            pos = position(ai, p)
            add!(worth, margin(pos) + pnl(pos, price)) #,  ai.cash * price)
        end
    end
    add!(worth, s.cash)
    worth
end

function lasttrade_date(ai)
    isempty(ai.history) ? ai.ohlcv.timestamp[end] : last(ai.history).date
end

function lasttrade_func(s)
    last_trade = tradesedge(s)[2]
    isnothing(last_trade) ? last : Returns(last_trade.date)
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

function tradesedge(::Type{DateTime}, s::Strategy)
    edges = tradesedge(s)
    edges[1].date, edges[2].date
end

function tradesrange(s::Strategy, tf=s.timeframe; start_pad=0, stop_pad=0)
    edges = tradesedge(DateTime, s)
    DateRange(edges[1] + tf * start_pad, edges[2] + tf * stop_pad, tf)
end
