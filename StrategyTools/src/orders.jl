
const TradeResult = Union{Missing,Nothing,<:Trade,<:OrderError}

@doc """ Selects an order type based on the strategy, order side, and position side

$(TYPEDSIGNATURES)

Selects an order type `os` based on the strategy `s` and the position side `p`. The order type is determined by the `ordertype` attribute of the strategy.
"""
function select_ordertype(s::Strategy, os::Type{<:OrderSide}, p::PositionSide=Long())
    t = s.attrs[:ordertype]
    if p == Long()
        if t == :market
            MarketOrder{os}, t
        elseif t == :ioc
            IOCOrder{os}, t
        elseif t == :fok
            FOKOrder{os}, t
        elseif t == :gtc
            GTCOrder{os}, t
        else
            error("Wrong order type $t")
        end
    else
        if t == :market
            ShortMarketOrder{os}, t
        elseif t == :ioc
            ShortIOCOrder{os}, t
        elseif t == :fok
            ShortFOKOrder{os}, t
        elseif t == :gtc
            ShortGTCOrder{os}, t
        else
            error("Wrong order type $t")
        end
    end
end

@doc """ Select additional keyword arguments for `Buy` orders based on order type

$(TYPEDSIGNATURES)

Depending on the order type symbol, additional keyword arguments are selected to define order parameters like price. This method specifically handles the `Buy` side logic by adjusting price based on closing value.
"""
function select_orderkwargs(otsym::Symbol, ::Type{Buy}, ai, ats)
    if otsym == :gtc
        (; price=1.02 * closeat(ohlcv(ai), ats))
    else
        ()
    end
end

@doc """ Selects an order type based on the strategy, order side, and position side

$(TYPEDSIGNATURES)

Selects an order type `os` based on the strategy `s` and the position side `p`. The order type is determined by the `ordertype` attribute of the strategy.
"""
function select_orderkwargs(otsym::Symbol, ::Type{Sell}, ai, ats)
    if otsym == :gtc
        (; price=0.99 * closeat(ohlcv(ai), ats))
    else
        ()
    end
end

@doc """ Checks if a trade was made recently

$(TYPEDSIGNATURES)

Checks if a trade was made recently by checking if the last trade time for the given asset instance is more recent than the current time frame. If no trades were made, it returns true.
"""
function isrecenttrade(ai::AssetInstance, ats::DateTime, tf::TimeFrame)
    ai_trades = trades(ai)
    last_trade_date = isempty(ai_trades) ? DateTime(0) : ai_trades[end].date
    if last_trade_date + tf > ats + tf
        @debug "surge: skipping since recent trade" ai
        true
    else
        false
    end
end
