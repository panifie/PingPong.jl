import .SimMode: maketrade
using .SimMode: @maketrade, iscashenough, cost
using .Executors.Instruments: compactnum as cnum
using .Misc.TimeToLive: safettl

function _check_and_filter(resp; ai, since, kind="")
    pyisinstance(resp, pybuiltins.list) || begin
        @warn "Couldn't fetch $kind trades for $(raw(ai))"
        return nothing
    end
    if isnothing(since)
        resp
    else
        out = pylist()
        for t in resp
            _timestamp(t) >= since && out.append(t)
        end
        out
    end
end

_timestamp(v) = pyconvert(Int, get_py(v, "timestamp", 0)) |> TimeTicks.dtstamp

function live_my_trades(s::LiveStrategy, ai; since=nothing, kwargs...)
    resp = fetch_my_trades(s, ai; since, kwargs...)
    _check_and_filter(resp; ai, since)
end

function live_order_trades(s::LiveStrategy, ai, id; since=nothing, kwargs...)
    resp = fetch_order_trades(s, ai, id; since, kwargs...)
    _check_and_filter(resp; ai, since, kind="order")
end

const Trf =
    TradeField = NamedTuple(
        Symbol(f) => f for f in (
            "id",
            "timestamp",
            "datetime",
            "symbol",
            "order",
            "type",
            "side",
            "takerOrMaker",
            "price",
            "amount",
            "cost",
            "fee",
            "fees",
            "currency",
            "rate",
        )
    )

function check_limits(v, ai, lim_sym)
    let lims = ai.limits,
        min = getproperty(lims, lim_sym).min,
        max = getproperty(lims, lim_sym).max

        if !(min < v < max)
            @warn "Trade amount $(v) outside limits ($(min)-$(max))"
        end
    end
end

const MARKETS_BY_CUR = safettl(Tuple{ExchangeID,String}, Vector{String}, Second(360))
function anyprice(cur::String, sym, exc)
    try
        v = lastprice(sym, exc)
        v <= zero(v) || return v
        for sym in @lget! MARKETS_BY_CUR (exchangeid(exc), cur) [
            k for k in Iterators.reverse(collect(keys(exc.markets))) if startswith(k, cur)
        ]
            v = lastprice(sym, exc)
            v <= zero(v) || return v
        end
        return ZERO
    catch
        return ZERO
    end
end

_feebysign(rate, cost) = rate >= ZERO ? cost : -cost
_getfee(fee_dict) = begin
    rate = get_float(fee_dict, "rate")
    cost = get_float(fee_dict, "cost")
    _feebysign(rate, cost)
end

function _feecost(fee_dict, ai; qc_py=@pystr(qc(ai)), bc_py=@pystr(qc(ai)))
    cur = get_py(fee_dict, "currency")
    if pyisTrue(cur == qc_py)
        (_getfee(fee_dict), ZERO)
    elseif pyisTrue(cur == bc_py)
        (ZERO, _getfee(fee_dict))
    else
        (ZERO, ZERO)
    end
end

# This tries to always convert the fees in quote currency
# function _feecost_quote(s, ai, bc_price, date, qc_py=@pystr(qc(ai)), bc_py=@pystr(bc(ai)))
#     if pyisTrue(cur == bc_py)
#         _feebysign(rate, cost * bc_price)
#     else
#         # Fee currency is neither quote nor base, fetch the price from the candle
#         # of the related spot pair with the trade quote currency at the trade date
#         try
#             spot_pair = "$cur/$qc_py"
#             price = @something priceat(s, ai, date; sym=spot_pair, step=:close) anyprice(
#                 string(cur), spot_pair, exchange(ai)
#             )
#             _feebysign(rate, cost * price)
#         catch
#         end
#     end
# end

function _tradefees(resp, ai)
    v = get_py(resp, Trf.fee)
    if pyisinstance(v, pybuiltins.dict)
        return _feecost(v, ai)
    end
    v = get_py(resp, Trf.fees)
    fees_quote, fees_base = ZERO, ZERO
    if pyisinstance(v, pybuiltins.list) && !isempty(v)
        qc_py = @pystr(qc(ai))
        bc_py = @pystr(bc(ai))
        for fee in v
            (q, b) = _feecost(fee, ai; qc_py, bc_py)
            fees_quote += q
            fees_base += b
        end
    end
    return (fees_quote, fees_base)
end

_addfees(net_cost, fees_quote, ::IncreaseOrder) = net_cost + fees_quote
_addfees(net_cost, fees_quote, ::ReduceOrder) = net_cost - fees_quote

function maketrade(s::LiveStrategy, o, ai; resp, kwargs...)
    pyisinstance(resp, pybuiltins.dict) || begin
        @warn "Invalid trade for order $(raw(ai)), order: $o"
        return nothing
    end
    get_py(resp, Trf.symbol, @pystr("")) == @pystr(raw(ai)) || begin
        @warn "Mismatching trade for $(raw(ai))($(get_py(resp, Trf.symbol))), order: $(o.asset)"
        return nothing
    end
    string(get_py(resp, Trf.order, @pystr(""))) == o.id || begin
        @warn "Mismatching trade order id $(raw(ai))($(get_py(resp, Trf.order))), order: $(o.id)"
        return nothing
    end
    actual_amount = get_float(resp, Trf.amount)
    check_limits(actual_amount, ai, :amount)
    actual_price = get_float(resp, Trf.price)
    check_limits(actual_price, ai, :price)
    net_cost = cost(actual_price, actual_amount)
    check_limits(net_cost, ai, :cost)

    iscashenough(s, ai, actual_amount, o) ||
        @warn "Live trade executed with non local cash, strategy ($(nameof(s)))) or asset ($(nameof(ai))) likely out of sync!"
    isapprox(net_cost, get_float(resp, Trf.cost)) || let
        rcv_cost = get_float(resp, Trf.cost)
        @warn "Unexpected trade cost (expected: $(cnum(net_cost)), received: $(cnum(rcv_cost)))"
    end

    fees_quote, fees_base = _tradefees(resp, ai)
    size = _addfees(net_cost, fees_quote, o)

    @maketrade
end
