using SimMode: create_sim_market_order, marketorder!, AnyFOKOrder, AnyIOCOrder
using Fetch: orderbook
using .Instances.Exchanges: ticker!, pyconvert
using .OrderTypes: ordertype, positionside, NotEnoughLiquidity, isimmediate
using .Executors: isfilled

@doc "A buy limit order is triggered when the price is lower than the limit."
_istriggered(o::AnyLimitOrder{Buy}, price) = price <= o.price
@doc "A sell limit order is triggered when the price is higher than the limit."
_istriggered(o::AnyLimitOrder{Sell}, price) = price >= o.price
@doc "Market orders are always triggered."
_istriggered(::AnyMarketOrder, args...) = true

@doc "Use the base currency volume from the ticker."
_basevol(ai) =
    let tkr = ticker!(ai.asset.raw, ai.exchange)
        pyconvert(DFT, tkr["baseVolume"])
    end
function _ticker_volume(ai)
    (Ref(apply(tf"1d", now())), Ref(0.0), Ref(_basevol(ai)))
end

_paper_liquidity(s, ai) = @lget! s[:paper_liquidity] ai _ticker_volume(ai)
@doc """ Limits the volume of order execution to the daily limit of the asset.

$(TYPEDSIGNATURES)

The function checks the liquidity and updates the daily volume, total volume, and taken volume accordingly.
It fails the market order if the daily volume for the current pair is exceeded.
The function uses the `@lget!` macro to get the values of `day_vol`, `taken_vol`, and `total_vol` from the `:paper_liquidity` attribute of the simulation `s`.
The function also uses the `_basevol` and `_ticker_volume` functions to get the base volume and ticker volume respectively.

"""
function volumecap!(s, ai; amount)
    # Check there is enough liquidity
    day_vol, taken_vol, total_vol = _paper_liquidity(s, ai)
    let this_day = apply(tf"1d", now())
        if this_day > day_vol[]
            day_vol[] = this_day
            total_vol[] = _basevol(ai)
            taken_vol[] = 0.0
        end
    end
    # fail the market order if we exceeded daily volume for current pair
    @debug "papermode: volumecap" taken_vol[] amount total_vol[]
    taken_vol[] + amount < total_vol[]
end

function orderbook_side(ai, t::Type{<:Order})
    ob = orderbook(ai.exchange, raw(ai); limit=100)
    side = ifelse(t <: AnyBuyOrder, :asks, :bids)
    @debug "papermode: obside" t side
    getproperty(ob, side)
end

@doc """ Simulates price and volume for an order from the live orderbook.

$(TYPEDSIGNATURES)

The function fetches the orderbook for the given asset and exchange.
It then calculates the volume-weighted average price (VWAP) based on how much of the orderbook the order sweeps.
If the order is a limit order and the average price exceeds the limit order price, the function terminates.
If the order is a Fill or Kill (FOK) order and the volume is less than the order amount, the function cancels the order.
The function updates the taken volume after each order.

"""
function from_orderbook(obside, s, ai, o::Order; amount, date)
    _, taken_vol, total_vol = s[:paper_liquidity][ai]
    n_prices = length(obside)
    @deassert n_prices > 0
    price_idx = max(1, trunc(Int, taken_vol[] * n_prices / total_vol[]))
    this_price, this_vol = obside[price_idx]
    @debug "paper from ob: idx" price_idx this_price this_vol
    this_vol = min(amount, this_vol)
    islimit = o isa AnyLimitOrder
    if islimit && !_istriggered(o, this_price)
        @debug "paper from ob: limit order not triggered" this_price o
        return this_price, zero(DFT), nothing
    end
    # calculate the vwap based on how much orderbook we sweep
    avg_price = this_price * this_vol
    while this_vol < amount
        price_idx += 1
        if price_idx > n_prices
            @debug "paper from ob: out of depth (!)" this_vol amount avg_price
            break
        end
        ob_price, ob_vol = obside[price_idx]
        # If it is a limit order terminate the loop as soon as avg_price
        # exceeds the limit order avg_price
        if islimit && !_istriggered(o, ob_price)
            @debug "paper from ob: limit order partially filled" o.price this_price amount this_vol avg_price
            break
        end
        inc_vol = min(ob_vol, amount - this_vol)
        avg_price += ob_price * inc_vol
        this_vol += inc_vol
    end
    avg_price /= this_vol
    ob_trade::Union{Nothing,<:Trade} = nothing
    if o isa AnyFOKOrder && this_vol < amount
        @debug "paper from ob: fok order no volume" o.price this_price amount this_vol
        cancel!(s, o, ai; err=NotEnoughLiquidity())
        return this_price, zero(DFT), nothing
    end
    prev_cash = s.cash.value
    ob_trade = trade!(
        s, o, ai; date, price=avg_price, actual_amount=this_vol, slippage=false
    )
    @debug "paper from ob:" s.cash.value - avg_price prev_cash this_vol ob_trade.value
    if isnothing(ob_trade) && o isa AnyFOKOrder
        @debug "paper from ob: fok order trade failed" o.price this_price amount this_vol
        cancel!(s, o, ai; err=OrderFailed((; o, obside)))
    end
    @assert o.amount ≈ this_vol ||
        o isa AnyLimitOrder ||
        # NOTE: this can fail only if orderbook hasn't enough vol
        sum(entry[2] for entry in obside) < o.amount (o.amount, this_vol)
    taken_vol[] += this_vol
    @debug "paper from ob: done" avg_price this_vol taken_vol[]
    return avg_price, this_vol, ob_trade
end
