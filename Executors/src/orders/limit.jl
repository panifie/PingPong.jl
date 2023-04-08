using Instances

##  committed::Float64 # committed is `cost + fees` for buying or `amount` for selling
const _LimitOrderState9 = NamedTuple{
    (:take, :stop, :committed, :filled, :trades),
    Tuple{Option{Float64},Option{Float64},Vector{Float64},Vector{Float64},Vector{Trade}},
}
function limit_order_state(take, stop, committed, filled=[0.0], trades=Trade[])
    _LimitOrderState9((take, stop, committed, filled, trades))
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
    OrderTypes.Order(
        ai,
        type;
        date,
        price,
        amount,
        committed,
        attrs=limit_order_state(take, stop, committed),
    )
end

function limitorder(
    s::Strategy,
    ai,
    amount;
    date,
    type,
    price=priceat(s, type, ai, date ),
    take=nothing,
    stop=nothing,
    kwargs...,
)
    @price! ai price take stop
    @amount! ai amount
    comm = committment(type, price, amount, maxfees(ai))
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

