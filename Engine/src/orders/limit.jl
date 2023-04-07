using ..Types.Orders: LimitOrderType, NotFilled, IOCOrder
##  committed::Float64 # committed is `cost + fees` for buying or `amount` for selling
const _LimitOrderState9 = NamedTuple{
    (:take, :stop, :committed, :filled, :trades),
    Tuple{Option{Float64},Option{Float64},Vector{Float64},Vector{Float64},Vector{Trade}},
}
function limit_order_state(take, stop, committed, filled=[0.0], trades=Trade[])
    _LimitOrderState9((take, stop, committed, filled, trades))
end

function limitorder(
    ai::AssetInstance,
    price,
    amount,
    committed,
    ::SanitizeOff;
    type=GTCOrder{Buy},
    date,
    take=nothing,
    stop=nothing,
)
    ismonotonic(stop, price, take) || return nothing
    iscost(ai, amount, stop, price, take) || return nothing
    Orders.Order(
        ai,
        type;
        date,
        price,
        amount,
        committed,
        attrs=limit_order_state(take, stop, committed),
    )
end

function committment(::Type{<:LimitOrder{Buy}}, price, amount, fees)
    [withfees(cost(price, amount), fees)]
end
function committment(::Type{<:LimitOrder{Sell}}, _, amount, _)
    [amount]
end

function iscommittable(s::Strategy, ::Type{<:BuyOrder}, commit, _)
    st.freecash(s) >= commit[1]
end
function iscommittable(_::Strategy, ::Type{<:SellOrder}, commit, ai)
    Instances.freecash(ai) >= commit[1]
end

# Pessimistic buy_high/sell_low
# _pricebyside(::Type{<:SellOrder}, ai, date) = st.lowat(ai, date)
# _pricebyside(::Type{<:BuyOrder}, ai, date) = st.highat(ai, date)
_pricebyside(::Type{<:Order}, ai, date) = st.closeat(ai, date)
_addslippage(o::LimitOrder{Buy}, price, slp) = min(o.price, price + slp)
_addslippage(o::LimitOrder{Sell}, price, slp) = max(o.price, price - slp)

function _pricebyslippage(s::Strategy, o::Order, ai, price, amount, volume)
    vol_ml = sim.slippage_rate(amount, volume)
    price_ml = sim.slippage_rate(price, o.price)
    ml = vol_ml + price_ml
    bs = _base_slippage(s, o.date, ai)
    slp = bs + bs * ml
    _addslippage(o, price, slp)
end

function limitorder(
    s::Strategy,
    ai,
    amount;
    date,
    type,
    price=_pricebyside(type, ai, available(s.timeframe, date)),
    take=nothing,
    stop=nothing,
    kwargs...,
)
    @price! ai price take stop
    @amount! ai amount
    comm = committment(type, price, amount, ai.fees)
    if iscommittable(s, type, comm, ai)
        limitorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

filled(o::LimitOrder) = o.attrs.filled[1]
committed(o::LimitOrder) = o.attrs.committed[1]
Base.fill!(o::LimitOrder{Buy}, t::BuyTrade) = begin
    o.attrs.filled[1] += t.amount
    o.attrs.committed[1] -= t.size
end
Base.fill!(o::LimitOrder{Sell}, t::SellTrade) = begin
    o.attrs.filled[1] += t.amount
    o.attrs.committed[1] -= t.amount
end
Base.isopen(o::LimitOrder) = o.attrs.filled[1] != o.amount
isfilled(o::LimitOrder) = o.attrs.filled[1] == o.amount
islastfill(o::LimitOrder, t::Trade) = t.amount != o.amount && isfilled(o)
isfirstfill(o::LimitOrder, args...) = o.attrs.filled[1] == 0.0
function _istriggered(o::LimitOrder{Buy}, date, ai)
    low = st.lowat(ai, date)
    low, low <= o.price
end
_istriggered(o::LimitOrder{Sell}, date, ai) = begin
    high = st.highat(ai, date)
    high, high >= o.price
end

@doc "Creates a simulated limit order."
function Executors.pong!(
    s::Strategy{Sim}, t::Type{<:Order{<:LimitOrderType}}, ai; amount, kwargs...
)
    o = limitorder(s, ai, amount; type=t, kwargs...)
    isnothing(o) && return nothing
    queue!(s, o, ai)
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Progresses a simulated limit order."
function Executors.pong!(
    s::Strategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...
)
    limitorder_ifprice!(s, o, date, ai)
end

@doc "Executes a limit order at a particular time only if price is lower(buy) than order price."
function limitorder_ifprice!(s::Strategy{Sim}, o::LimitOrder, date, ai)
    this_price, t = _istriggered(o, date, ai)
    if t
        limitorder_ifvol!(s, o, this_price, date, ai)
    elseif o isa Union{FOKOrder,IOCOrder}
        cancel!(s, o, ai; err=NotMatched(o.price, this_price, 0.0, 0.0))
    else
        missing
    end
end

@doc """
If the buy (sell) price is higher (lower) than current price, starting from
current price we add (remove) slippage. We ensure that price after slippage
adjustement doesn't exceed the *limit* order price.
=== Buy ===
buy_order_price
...
slip_price
...
current_price
...
slip_price
...
sell_order_price
=== Sell ===
"""
function _check_slipprice(slip_price, o::LimitOrder{Buy}, ai, date)
    price = st.lowat(ai, date)
    ((o.price >= price) && (price <= slip_price <= o.price)) ||
        ((o.price < price) && slip_price == o.price)
end

function _check_slipprice(slip_price, o::LimitOrder{Sell}, ai, date)
    price = st.highat(ai, date)
    ((o.price <= price) && (o.price <= slip_price <= price)) ||
        ((o.price > price) && slip_price == o.price)
end

@doc "Executes a limit order at a particular time according to volume (called by `limitorder_ifprice!`)."
function limitorder_ifvol!(s::Strategy{Sim}, o::LimitOrder, price, date, ai)
    cdl_vol = st.volumeat(ai, date)
    amount = o.amount - filled(o)
    if amount < cdl_vol # One trade fills the order completely
        price = _pricebyslippage(s, o, ai, price, amount, cdl_vol)
        @assert _check_slipprice(price, o, ai, date)
        trade!(s, o, ai; date, price=price, amount)
    elseif cdl_vol > 0.0 && !(o isa FOKOrder)  # Partial fill (Skip partial fills for FOK orders)
        price = _pricebyslippage(s, o, ai, price, amount, cdl_vol)
        @assert _check_slipprice(price, o, ai, date)
        tr = trade!(s, o, ai; date, price, amount=cdl_vol)
        # Cancel IOC orders after partial fill
        o isa IOCOrder && cancel!(s, o, ai; err=NotFilled(amount, cdl_vol))
        tr
    elseif o isa Union{FOKOrder,IOCOrder}
        cancel!(s, o, ai; err=NotMatched(price, price, amount, cdl_vol))
    else
        missing
    end
end
