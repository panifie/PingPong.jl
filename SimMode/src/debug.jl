using OrderTypes: LimitOrderType, ordertype

const CTR = Ref(0)
const CTO = Ref(0)
const PRICE_CHECKS = Ref(0)
const VOL_CHECKS = Ref(0)
const cash_tracking = Float64[]
_vv(v) = v isa Vector ? v[] : v
function _showcash(s, ai)
    @show s.cash s.cash_committed ai.cash ai.cash_committed
end
function _showorder(o)
    display(("price: ", o.price))
    display(("comm: ", _vv(o.attrs.committed)))
    display(("fill: ", _vv(o.attrs.unfilled)))
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
            cash_comm += committed(o)
        end
    end
    @assert isapprox(cash_comm, s.cash_committed, atol=1e-6) (
        cash_comm, s.cash_committed.value
    )
end

function _check_committments(s, ai::AssetInstance, t::Trade)
    ordertype(t) <: LimitOrderType || return nothing
    @show ai.longpos.cash_committed
    @show ai.shortpos.cash_committed
    long_comm = 0.0
    short_comm = 0.0
    for (_, o) in s.sellorders[ai]
        if o isa LongOrder
            long_comm += committed(o)
        else
            short_comm += committed(o)
        end
    end
    cc_long = committed(ai, Long())
    cc_short = committed(ai, Short())
    @assert isapprox(long_comm, cc_long, atol=1e-6) (long_comm, cc_long, Long)
    @assert isapprox(short_comm, cc_short, atol=1e-6) (short_comm, cc_short, Short)
end
