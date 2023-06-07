import Data: candleat, openat, highat, lowat, closeat, volumeat, closelast
using Instances: pnl, position, margin
using Instruments
using Instruments: @importcash!, AbstractCash
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

@doc "The asset close price of the candle where the last trade was performed."
lasttrade_price_func(ai) = closeat(ai, lasttrade_date(ai))

function current_total(
    s::NoMarginStrategy, price_func=lasttrade_price_func; cash_type::Type{C}=Cash
) where {C<:AbstractCash}
    worth = C(s.cash, 0.0)
    for ai in s.holdings
        add!(worth, ai.cash * price_func(ai))
    end
    add!(worth, s.cash)
    worth
end

function current_total(
    s::MarginStrategy, price_func=lasttrade_price_func; cash_type::Type{C}=Cash
) where {C<:AbstractCash}
    worth = C(s.cash, 0.0)
    for ai in s.holdings
        for p in (Long, Short)
            isopen(ai, p) || continue
            add!(worth, value(ai, p, price_func(ai))) #,  ai.cash * price)
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

@doc "The first and last trade of any asset in the strategy universe."
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

@doc "The dates of the first and last trade present in the strategy."
function tradesedge(::Type{DateTime}, s::Strategy)
    edges = tradesedge(s)
    edges[1].date, edges[2].date
end

@doc "The recorded trading `Period`, from the trades history present in the strategy."
function tradesperiod(s::Strategy)
    start, stop = tradesedge(DateTime, s)
    stop - start
end

@doc "A `DateRange` spanning the historical time period of the trades recorded by the strategy."
function tradesrange(s::Strategy, tf=s.timeframe; start_pad=0, stop_pad=0)
    edges = tradesedge(DateTime, s)
    DateRange(edges[1] + tf * start_pad, edges[2] + tf * stop_pad, tf)
end

_setmax!(d, k, v) = d[k] = max(get(d, k, v), v)
_sizehint!(c, d, k, f=length) = Base.sizehint!(c, _setmax!(d, k, f(c)))
@doc "Keeps track of max allocated containers size for strategy and asset instances in the universe."
function sizehint!(s::Strategy)
    sizes = @lget! s.attrs :_sizes Dict{Symbol,Union{Dict,Int}}()
    s_sizes = @lget! sizes :_s_sizes Dict{Symbol,Int}()
    _sizehint!(s.buyorders, s_sizes, :buyorders)
    _sizehint!(s.sellorders, s_sizes, :sellorders)
    _sizehint!(s.holdings, s_sizes, :holdings)
    _sizehint!(s.logs, s_sizes, :logs)
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
    for ai in s.universe
        _sizehint!(ai.history, ai_sizes, ai.asset.raw)
        _sizehint!(ai.logs, ai_logs_sizes, ai.asset.raw)
    end
end
