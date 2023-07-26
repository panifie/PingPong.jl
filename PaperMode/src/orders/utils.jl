using SimMode: create_sim_market_order, marketorder!, AnyFOKOrder, AnyIOCOrder
using Fetch: orderbook
using .Instances.Exchanges: ticker!, pyconvert
using .OrderTypes: ordertype, positionside, NotEnoughLiquidity, isatomic
using Executors: isfilled

_istriggered(o::AnyLimitOrder{Buy}, price) = price <= o.price
_istriggered(o::AnyLimitOrder{Sell}, price) = price >= o.price
_istriggered(::AnyMarketOrder, args...) = true

_basevol(ai) =
    let tkr = ticker!(ai.asset.raw, ai.exchange)
        pyconvert(DFT, tkr["baseVolume"])
    end
function _ticker_volume(ai)
    (Ref(apply(tf"1d", now())), Ref(0.0), Ref(_basevol(ai)))
end

@doc "Limit volume capacity of order execution to the daily limit of the asset."
function volumecap!(s, ai; amount)
    # Check there is enough liquidity
    day_vol, taken_vol, total_vol = @lget! attr(s, :paper_liquidity) ai _ticker_volume(ai)
    let this_day = apply(tf"1d", now())
        if this_day > day_vol[]
            day_vol[] = this_day
            total_vol[] = _basevol(ai)
            taken_vol[] = 0.0
        end
    end
    # fail the market order if we exceeded daily volume for current pair
    taken_vol[] + amount < total_vol[]
end

function orderbook_side(ai, t::Type{<:Order})
    ob = orderbook(ai.exchange, ai.asset.raw; limit=100)
    getproperty(ob, ifelse(t <: BuyOrder, :asks, :bids))
end
_obsidebypos(::Long) = :asks
_obsidebypos(::Short) = :bids
function orderbook_side(ai, ::OrderTypes.ByPos{P}) where {P}
    ob = orderbook(ai.exchange, ai.asset.raw; limit=100)
    getproperty(ob, _obsidebypos(P()))
end

@doc "Simulate price and volume for an order from the live orderbook."
function from_orderbook(obside, s, ai, o::Order; amount, date)
    _, taken_vol, total_vol = attr(s, :paper_liquidity)[ai]
    n_prices = length(obside)
    @deassert n_prices > 0
    price_idx = max(1, trunc(Int, taken_vol[] * n_prices / total_vol[]))
    this_price, this_vol = obside[price_idx]
    this_vol = min(amount, this_vol)
    islimit = o isa AnyLimitOrder
    islimit && !_istriggered(o, this_price) && return this_price, zero(DFT), nothing
    # calculate the vwap based on how much orderbook we sweep
    avg_price = this_price * this_vol
    while this_vol < amount
        price_idx += 1
        price_idx > n_prices && break
        ob_price, ob_vol = obside[price_idx]
        # If it is a limit order terminate the loop as soon as avg_price
        # exceeds the limit order avg_price
        islimit && !_istriggered(o, ob_price) && break
        inc_vol = min(ob_vol, amount - this_vol)
        avg_price += ob_price * inc_vol
        this_vol += inc_vol
    end
    avg_price /= this_vol
    ob_trade = nothing::Union{Nothing,<:Trade}
    if o isa AnyFOKOrder && this_vol < amount
        cancel!(s, o, ai; err=NotEnoughLiquidity())
        return this_price, zero(DFT), nothing
    end
    ob_trade = trade!(
        s, o, ai; date, price=avg_price, actual_amount=this_vol, slippage=false
    )
    if isnothing(ob_trade) && o isa AnyFOKOrder
        cancel!(s, o, ai; err=OrderFailed("FOK order for $(ai.asset) failed $(o.date)."))
    end
    @assert o.amount ≈ this_vol ||
        o isa AnyLimitOrder ||
        # NOTE: this can fail only if orderbook hasn't enough vol
        sum(entry[2] for entry in obside) < o.amount (o.amount, this_vol)
    taken_vol[] += this_vol
    return avg_price, this_vol, ob_trade
end

