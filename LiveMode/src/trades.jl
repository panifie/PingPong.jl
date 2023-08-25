import .SimMode: maketrade, trade!
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
    lims = ai.limits
    min = getproperty(lims, lim_sym).min
    max = getproperty(lims, lim_sym).max

    min <= v <= max || begin
        @warn "Trade amount $(v) outside limits ($(min)-$(max))"
        return false
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
_getfee(fee_dict, cost=get_float(fee_dict, "cost")) = begin
    rate = get_float(fee_dict, "rate")
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

function trade_feecur(ai, side::Type{<:OrderSide})
    # Default to get since it should be the most common
    feeside = get(market(ai), "feeSide", "get")
    if feeside == "get"
        if side == Buy
            :base
        else
            :quote
        end
    elseif feeside == "give"
        if side == Sell
            :base
        else
            :quote
        end
    elseif feeside == "quote"
        :quote
    elseif feeside == "base"
        :base
    else
        :quote
    end
end

function _default_trade_fees(
    ai, side::Type{<:OrderSide}; fees_base, fees_quote, actual_amount, net_cost
)
    feecur = trade_feecur(ai, side)
    default_fees = maxfees(ai)
    if feecur == :base
        fees_base += actual_amount * default_fees
    else
        fees_quote += net_cost * default_fees
    end
    (fees_quote, fees_base)
end

market(ai) = exchange(ai).markets[raw(ai)]
function _tradefees(resp, side, ai; actual_amount, net_cost)
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
    if iszero(fees_quote) && iszero(fees_base)
        (fees_quote, fees_base) = _default_trade_fees(
            ai, side; fees_base, fees_quote, actual_amount, net_cost
        )
    end
    return (fees_quote, fees_base)
end

_addfees(net_cost, fees_quote, ::IncreaseOrder) = net_cost + fees_quote
_addfees(net_cost, fees_quote, ::ReduceOrder) = net_cost - fees_quote

function _check_symbol(ai, o, resp)::Bool
    pyisTrue(get_py(resp, Trf.symbol, @pystr("")) == @pystr(raw(ai))) || begin
        @warn "Mismatching trade for $(raw(ai))($(get_py(resp, Trf.symbol))), order: $(o.asset), aborting."
        return false
    end
end

function _check_type(ai, o, resp)::Bool
    pyisinstance(resp, pybuiltins.dict) || begin
        @warn "Invalid trade for order $(raw(ai)), order: $o, aborting."
        return false
    end
end

function _check_id(ai, o, resp; k=Trf.order)::Bool
    string(get_py(resp, k, @pystr(""))) == o.id || begin
        @warn "Mismatching trade order id $(raw(ai))($(get_py(resp, Trf.order))), order: $(o.id), aborting."
        return false
    end
end

function _tradeside(resp, o)::Type{<:OrderSide}
    side = get_py(resp, Trf.side, nothing)
    if pyisTrue(side == @pystr("buy"))
        Buy
    elseif pyisTrue(side == @pystr("sell"))
        Sell
    else
        orderside(o)
    end
end
function _check_side(side, o)::Bool
    side == orderside(o) || begin
        @warn "Mismatching trade side $side and order side $(orderside(o)), aborting."
        return false
    end
end

function _check_price(s, ai, actual_price)::Bool
    actual_price > ZERO || begin
        @warn "Trade price can't be zero, aborting! ($(nameof(s)) @ ($(raw(ai))) tradeid: ($(get_string(resp, "id"))), aborting."
        return false
    end
end

function _warn_cash(s, ai, o; actual_amount)
    iscashenough(s, ai, actual_amount, o) ||
        @warn "Live trade executed with non local cash, strategy ($(nameof(s)))) or asset ($(raw(ai))) likely out of sync!"
end

function maketrade(s::LiveStrategy, o, ai; resp, trade::Option{Trade}=nothing, kwargs...)
    trade isa Trade && return trade
    _check_type(ai, o, resp) || return nothing
    _check_symbol(ai, o, resp) || return nothing
    _check_id(ai, o, resp) || return nothing
    side = _tradeside(resp, o)
    _check_side(side, o) || return nothing
    actual_amount = get_float(resp, Trf.amount)
    actual_price = get_float(resp, Trf.price)
    _check_price(s, ai, actual_price) || return nothing
    check_limits(actual_price, ai, :price)
    if actual_amount <= ZERO
        @debug "Amount value absent from trade or wrong ($actual_amount)), using cost."
        net_cost = get_float(resp, "cost")
        actual_amount = net_cost / actual_price
    else
        net_cost = cost(actual_price, actual_amount)
    end
    check_limits(net_cost, ai, :cost)
    check_limits(actual_amount, ai, :amount)

    _warn_cash(s, ai, o; actual_amount)
    date = @something pytodate(resp) now()

    fees_quote, fees_base = _tradefees(resp, side, ai; actual_amount, net_cost)
    size = _addfees(net_cost, fees_quote, o)

    @maketrade
end
