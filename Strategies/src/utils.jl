import .Data: candleat, openat, highat, lowat, closeat, volumeat, closelast
using .Data.DFUtils: firstdate, lastdate
using .Instances: pnl, position, margin
using .Instruments
using .Instruments: @importcash!, AbstractCash
@importcash!

@doc "Get the candle for the asset at `date` with timeframe `tf`."
function candleat(ai::AssetInstance, date, tf; kwargs...)
    candleat(ai.data[tf], date; kwargs...)
end

function candleat(s::Strategy, ai::AssetInstance, date; tf=s.timeframe, kwargs...)
    candleat(ai, date, tf; kwargs...)
end

@doc """ Defines a set of functions for a given candle function.

$(TYPEDSIGNATURES)

This macro generates two functions for each candle function passed to it.
The first function is for getting the candle data from an `AssetInstance` at a specific date.
The second function is for getting the candle data from a `Strategy` at a specific date with a specified timeframe.
The timeframe defaults to the strategy's timeframe if not provided.

"""
macro define_candle_func(fname)
    fname = esc(Symbol(eval(fname)))
    ex1 = quote
        function func(ai::AssetInstance, date; kwargs...)
            func(ohlcv(ai), date; kwargs...)
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

@doc "The asset close price of the candle where the last trade was performed."
lasttrade_price_func(ai) = begin
    h = ai.history
    data = ohlcv(ai)
    if !isempty(h)
        h[end].price
    elseif !isempty(data)
        data.close[end]
    else
        0.0
    end
end

current_total(s, price_func; kwargs...) = current_total(s; price_func, kwargs...)

@doc """ Calculates the total value of a NoMarginStrategy.

$(TYPEDSIGNATURES)

This function calculates the total value of a `NoMarginStrategy` by summing up the value of all holdings and cash.
The value of each holding is calculated using a provided price function.
The default price function used is `lasttrade_price_func`, which returns the closing price of the last trade.

"""
function current_total(s::NoMarginStrategy{Sim}; price_func=lasttrade_price_func, kwargs...)
    worth = zero(DFT)
    for ai in s.holdings
        worth += cash(ai) * price_func(ai)
    end
    worth + cash(s)
end

@doc """ Calculates the total value of a NoMarginStrategy with Paper.

$(TYPEDSIGNATURES)

This function calculates the total value of a `NoMarginStrategy{Paper}` by summing up the value of all holdings and cash.
The value of each holding is calculated using a provided price function.
The default price function used is `lasttrade_price_func`, which returns the closing price of the last trade.

"""
function current_total(
    s::NoMarginStrategy{Paper}; price_func=lasttrade_price_func, kwargs...
)
    worth = Ref(zero(DFT))
    @sync for ai in s.holdings
        @async worth[] += cash(ai) * price_func(ai)
    end
    worth[] + cash(s)
end

@doc """ Calculates the total value of a MarginStrategy.

$(TYPEDSIGNATURES)

This function calculates the total value of a `MarginStrategy` by summing up the value of all holdings and cash.
The value of each holding is calculated using a provided price function.
The default price function used is `lasttrade_price_func`, which returns the closing price of the last trade.

"""
function current_total(s::MarginStrategy{Sim}; price_func=lasttrade_price_func, kwargs...)
    worth = zero(DFT)
    for ai in s.holdings
        for p in (Long, Short)
            if isopen(ai, p)
                worth += value(ai, p; current_price=price_func(ai))
            end
        end
    end
    worth + cash(s)
end

@doc """ Calculates the total value of a MarginStrategy with Paper.

$(TYPEDSIGNATURES)

This function calculates the total value of a `MarginStrategy{Paper}` by summing up the value of all holdings and cash.
The value of each holding is calculated using a provided price function.
The default price function used is `lasttrade_price_func`, which returns the closing price of the last trade.

"""
function current_total(s::MarginStrategy{Paper}, price_func=lasttrade_price_func; kwargs...)
    worth = Ref(zero(DFT))
    @sync for ai in s.holdings
        @async let current_price = price_func(ai)
            for p in (Long, Short)
                if isopen(ai, p)
                    worth[] += value(ai, p; current_price)
                end
            end
        end
    end
    worth[] + s.cash
end

@doc """ Returns the date of the last trade for an asset instance.

$(TYPEDSIGNATURES)

This function returns the date of the last trade for an `AssetInstance`.
If the history of the asset instance is empty, it returns the timestamp of the last candle.

"""
function lasttrade_date(ai, def=ohlcv(ai).timestamp[end])
    isempty(ai.history) ? def : last(ai.history).date
end

@doc """ Returns a function for the last trade date of a strategy.

$(TYPEDSIGNATURES)

This function returns a function that, when called, gives the date of the last trade for a `Strategy`.
If there is no last trade, it returns the `last` function.

"""
function lasttrade_func(s)
    last_trade = tradesedge(s)[2]
    isnothing(last_trade) ? last : Returns(last_trade.date)
end

@doc """ Returns the first and last trade of any asset in the strategy universe.

$(TYPEDSIGNATURES)

This function returns the first and last trade of any asset in the strategy universe for a given `Strategy`.
If there are no trades, it returns `nothing`.

"""
function tradesedge(s::Strategy)
    first_trade = nothing
    last_trade = nothing
    for ai in universe(s)
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

@doc """ Returns the dates of the first and last trade present in the strategy.

$(TYPEDSIGNATURES)

This function returns the dates of the first and last trade of any asset in the strategy universe for a given `Strategy`.

"""
function tradesedge(::Type{DateTime}, s::Strategy)
    edges = tradesedge(s)
    edges[1].date, edges[2].date
end

@doc """ Returns the recorded trading period from the trades history present in the strategy.

$(TYPEDSIGNATURES)

This function returns the recorded trading period from the trades history present in the strategy.
It calculates the period by subtracting the start date from the stop date.

"""
function tradesperiod(s::Strategy)
    start, stop = tradesedge(DateTime, s)
    stop - start
end

@doc """ Returns a `DateRange` spanning the historical time period of the trades recorded by the strategy.

$(TYPEDSIGNATURES)

This function returns a `DateRange` that spans the historical time period of the trades recorded by the strategy.
It calculates the range by adding the start and stop pads to the edges of the trades.

"""
function tradesrange(s::Strategy, tf=s.timeframe; start_pad=0, stop_pad=0)
    edges = tradesedge(DateTime, s)
    DateRange(edges[1] + tf * start_pad, edges[2] + tf * stop_pad, tf)
end

_setmax!(d, k, v) = d[k] = max(get(d, k, v), v)
_sizehint!(c, d, k, f=length) = Base.sizehint!(c, _setmax!(d, k, f(c)))
@doc """ Keeps track of max allocated containers size for strategy and asset instances in the universe.

$(TYPEDSIGNATURES)

This function keeps track of the maximum allocated containers size for strategy and asset instances in the universe.
It updates the sizes of various containers based on the current state of the strategy.

"""
function sizehint!(s::Strategy)
    sizes = @lget! attrs(s) :_sizes Dict{Symbol,Union{Dict,Int}}()
    s_sizes = @lget! sizes :_s_sizes Dict{Symbol,Int}()
    _sizehint!(s.buyorders, s_sizes, :buyorders)
    _sizehint!(s.sellorders, s_sizes, :sellorders)
    _sizehint!(s.holdings, s_sizes, :holdings)
    o_b_sizes = @lget! sizes :_ob_sizes Dict{String,Int}()
    for (ai, d) in s.buyorders
        _sizehint!(d, o_b_sizes, ai.asset.raw)
    end
    o_s_sizes = @lget! sizes :_os_sizes Dict{String,Int}()
    for (ai, d) in s.sellorders
        _sizehint!(d, o_s_sizes, ai.asset.raw)
    end
    ai_sizes = @lget! sizes :_ai_sizes Dict{String,Int}()
    ai_logs_sizes = @lget! sizes :_ai_logs_sizes Dict{String,Int}()
    for ai in universe(s)
        _sizehint!(ai.history, ai_sizes, ai.asset.raw)
    end
end
