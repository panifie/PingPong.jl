
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
    side=LimitOrder{Buy},
    date,
    take=nothing,
    stop=nothing,
)
    ismonotonic(stop, price, take) || return nothing
    iscost(ai, amount, stop, price, take) || return nothing
    Orders.Order(
        ai,
        side;
        date,
        price,
        amount,
        committed,
        attrs=limit_order_state(take, stop, committed),
    )
end

function committment(::Type{LimitOrder{Buy}}, price, amount, fees)
    [withfees(cost(price, amount), fees)]
end
function committment(::Type{LimitOrder{Sell}}, _, amount, _)
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

function limitorder(
    s::Strategy,
    ai,
    amount;
    date,
    side,
    price=_pricebyside(side, ai, date - s.timeframe),
    take=nothing,
    stop=nothing,
    kwargs...,
)
    @price! ai price take stop
    @amount! ai amount
    committed = committment(side, price, amount, ai.fees)
    if iscommittable(s, side, committed, ai)
        limitorder(ai, price, amount, committed, SanitizeOff(); date, side, kwargs...)
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
isfirstfill(o::LimitOrder, args...) = o.attrs.filled[1] == 0
_istriggered(o::LimitOrder{Buy}, date, ai) = st.lowat(ai, date) <= o.price
_istriggered(o::LimitOrder{Sell}, date, ai) = st.highat(ai, date) >= o.price

@doc "Creates a simulated limit order."
function Executors.pong!(s::Strategy{Sim}, t::Type{<:LimitOrder}, ai; amount, kwargs...)
    o = limitorder(s, ai, amount; side=t, kwargs...)
    isnothing(o) && return nothing
    queue!(s, o, ai)
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Progresses a simulated limit order."
function Executors.pong!(
    s::Strategy{Sim}, o::Order{<:LimitOrder}, date::DateTime, ai; kwargs...
)
    limitorder_ifprice!(s, o, date, ai)
end

@doc "Executes a limit order at a particular time only if price is lower(buy) than order price."
function limitorder_ifprice!(s::Strategy{Sim}, o::LimitOrder, date, ai)
    if _istriggered(o, date, ai)
        limitorder_ifvol!(s, o, date, ai)
    else
        missing
    end
end

@doc "Executes a limit order at a particular time according to volume (called by `limitorder_ifprice!`)."
function limitorder_ifvol!(s::Strategy{Sim}, o::LimitOrder, date, ai)
    cdl_vol = st.volumeat(ai, date)
    avl_volume = cdl_vol * _takevol(s)
    amount = o.amount - filled(o)
    if amount < avl_volume # One trade fills the order completely
        trade!(s, o, ai; date, amount)
    elseif avl_volume > 0.0 # Partial fill
        trade!(s, o, ai; date, amount=avl_volume)
    else
        missing
    end
end
