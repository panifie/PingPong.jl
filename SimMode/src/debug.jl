using OrderTypes: LimitOrderType, ordertype

const CTR = Ref(0)
const CTO = Ref(0)
const PRICE_CHECKS = Ref(0)
const VOL_CHECKS = Ref(0)
const cash_tracking = Float64[]
_vv(v) = v isa Vector ? v[] : v
function _showcash(s, ai)
    @show s.cash s.cash_committed cash(ai) committed(ai)
end
function _showorder(o)
    display(("price: ", o.price))
    display(("comm: ", _vv(o.attrs.committed)))
    display(("unfill: ", _vv(o.attrs.unfilled)))
    display(("amount: ", o.amount))
    display(("trades: ", length(o.attrs.trades)))
end
function _globals()
    @show PRICE_CHECKS VOL_CHECKS CTR CTO
    nothing
end
function _resetglobals!()
    CTR[] = 0
    CTO[] = 0
    PRICE_CHECKS[] = 0
    VOL_CHECKS[] = 0
    empty!(cash_tracking)
end
function _afterorder()
    CTO[] += 1
end
function _beforetrade(s, ai, o, trade, actual_price)
    @assert trade.size != 0.0 "Trade must not be empty, size was $(trade.size)."
    CTR[] += 1
    push!(cash_tracking, actual_price)
    get(s.attrs, :verbose, false) || return nothing
    _showcash(s, ai)
    _showorder(o)
end

function _aftertrade(s, ai, o)
    get(s.attrs, :verbose, false) || return nothing
    _showorder(o)
    _showcash(s, ai)
    println("\n")
    get(s.attrs, :debug_maxtrades, Inf) == CTR[] && error()
end

function _check_committments(s::Strategy)
    cash_comm = 0.0
    for (_, ords) in s.buyorders
        for (_, o) in ords
            o isa Union{ShortBuyOrder} && continue
            cash_comm += committed(o)
        end
    end
    @assert isapprox(cash_comm, s.cash_committed, atol=1e-6) (
        cash_comm, s.cash_committed.value
    )
end

function _check_committments(s, ai::AssetInstance, t::Trade)
    ordertype(t) <: LimitOrderType || return nothing
    get(s.attrs, :verbose, false) && begin
        @show (@something ai.longpos ai).cash_committed
        @show (@something ai.shortpos ai).cash_committed
    end
    orders_long = 0.0
    orders_short = 0.0
    for (_, o) in orders(s, ai, orderpos(t)())
        if o isa SellOrder
            orders_long += committed(o)
        elseif o isa ShortBuyOrder
            orders_short += committed(o)
        end
    end
    asset_long = committed(ai, Long())
    asset_short = committed(ai, Short())
    if t isa ShortBuyTrade
        asset_short -= committed(t.order)
    end
    @assert isapprox(orders_long, asset_long, atol=1e-6) (;orders_long, asset_long, Long)
    @assert isapprox(orders_short, asset_short, atol=1e-6) (;orders_short, asset_short, Short),
    collect(values(s.sellorders[ai]))
end
