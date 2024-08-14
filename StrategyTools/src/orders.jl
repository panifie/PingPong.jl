
const TradeResult = Union{Missing,Nothing,<:Trade,<:OrderError}

@doc """ Selects an order type based on the strategy, order side, and position side

$(TYPEDSIGNATURES)

Selects an order type `os` based on the strategy `s` and the position side `p`. The order type is determined by the `ordertype` attribute of the strategy.
"""
function select_ordertype(s::Strategy, os::Type{<:OrderSide}, p::PositionSide=Long(); t=s.ordertype)
    if p == Long()
        if t == :market
            MarketOrder{os}, t
        elseif t == :ioc
            IOCOrder{os}, t
        elseif t == :fok
            FOKOrder{os}, t
        elseif t == :gtc
            GTCOrder{os}, t
        elseif t == :po
            PostOnlyOrder{os}, t
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
        elseif t == :po
            ShortPostOnlyOrder{os}, t
        else
            error("Wrong order type $t")
        end
    end
end

function price_from_trades(ai)
    h = trades(ai)
    t = get(h, lastindex(h), missing)
    if !ismissing(t)
        t.price
    else
        missing
    end
end

@doc """ Select additional keyword arguments for `Buy` orders based on order type

$(TYPEDSIGNATURES)

Depending on the order type symbol, additional keyword arguments are selected to define order parameters like price. This method specifically handles the `Buy` side logic by adjusting price based on closing value.
"""
function select_orderkwargs(otsym::Symbol, ::Type{Buy}, ai, ats; incr=(buy=1.02, sell=0.99))
    price = @coalesce price_from_trades(ai) closeat(ai, ats)
    if otsym in (:gtc, :po)
        (; price=incr.buy * price)
    else
        (;)
    end
end

@doc """ Selects an order type based on the strategy, order side, and position side

$(TYPEDSIGNATURES)

Selects an order type `os` based on the strategy `s` and the position side `p`. The order type is determined by the `ordertype` attribute of the strategy.
"""
function select_orderkwargs(otsym::Symbol, ::Type{Sell}, ai, ats; incr=(; buy=1.02, sell=0.99))
    price = @coalesce price_from_trades(ai) closeat(ai, ats)
    if otsym in (:gtc, :po)
        (; price=incr.sell * price)
    else
        (;)
    end
end

@doc """ Checks if a trade was made recently

$(TYPEDSIGNATURES)

Checks if a trade was made recently by checking if the last trade time for the given asset instance is more recent than the current time frame. If no trades were made, it returns true.
"""
function isrecenttrade(ai::AssetInstance, ats::DateTime, tf::TimeFrame; cd=tf)
    ai_trades = trades(ai)
    last_trade_date = isempty(ai_trades) ? DateTime(0) : ai_trades[end].date
    if last_trade_date + cd > ats + tf
        @debug "surge: skipping since recent trade" ai
        true
    else
        false
    end
end
