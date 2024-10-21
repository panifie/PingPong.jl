import .SimMode: maketrade, trade!
using .SimMode: @maketrade, iscashenough, cost
using .Misc.TimeToLive: safettl
using .Misc: toprecision

@doc """ Checks and filters trades based on a timestamp.

$(TYPEDSIGNATURES)

The function checks if the response is a list. If not, it issues a warning and returns `nothing`.
If a `since` timestamp is provided, it filters out trades that occurred before this timestamp.
The function returns the filtered list of trades or the original response if no `since` timestamp is provided.

"""
function _check_and_filter(resp; ai, since, kind="")
    if resp isa Vector
        if isnothing(since)
            resp
        else
            filter(t -> trade_timestamp(t, exchangeid(ai)) >= since, resp)
        end
    elseif pyisinstance(resp, pybuiltins.list)
        if isnothing(since)
            resp
        else
            out = pylist()
            for t in resp
                trade_timestamp(t, exchangeid(ai)) >= since && out.append(t)
            end
            out
        end
    else
        @warn "Couldn't fetch $kind trades for $(raw(ai))"
        return nothing
    end
end

function trade_timestamp(v, eid::EIDType)
    pyconvert(Int, resp_trade_timestamp(v, eid)) |> TimeTicks.dtstamp
end

@doc """ Fetches and filters the user's trades.

$(TYPEDSIGNATURES)

The function fetches the user's trades using the `fetch_my_trades` function.
If a `since` timestamp is provided, it filters out trades that occurred before this timestamp using the `_check_and_filter` function.
The function returns the filtered list of trades or the original response if no `since` timestamp is provided.

"""
function live_my_trades(s::LiveStrategy, ai; since=nothing, kwargs...)
    resp = fetch_my_trades(s, ai; since, kwargs...)
    _check_and_filter(resp; ai, since)
end

@doc """ Fetches and filters trades for a specific order

$(TYPEDSIGNATURES)

This function fetches the trades associated with a specific order using the `fetch_order_trades` function.
If a `since` timestamp is provided, it filters out trades that occurred before this timestamp using the `_check_and_filter` function.
The function returns the filtered list of trades or the original response if no `since` timestamp is provided.

"""
function live_order_trades(s::LiveStrategy, ai, id; since=nothing, kwargs...)
    resp = fetch_order_trades(s, ai, id; since, kwargs...)
    _check_and_filter(resp; ai, since, kind="order")
end

@doc "A named tuple representing the ccxt fields of a trade."
const Trf = NamedTuple(
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

function inlimits(v, ai, lim_sym)
    lims = ai.limits
    min = getproperty(lims, lim_sym).min
    max = getproperty(lims, lim_sym).max

    if v < min || v > max
        @warn "create trade: value outside bounds" lim_sym v min max
        false
    else
        true
    end
end

@doc "A cache for storing market symbols by currency with a time-to-live of 360 seconds."
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
        return 0.0
    catch
        return 0.0
    end
end

_feebysign(rate, cost) = rate >= 0.0 ? cost : -cost
@doc """ Calculates the fee from a fee dictionary

$(TYPEDSIGNATURES)

This function calculates the fee from a fee dictionary.
It retrieves the rate and cost from the fee dictionary and then uses the `_feebysign` function to calculate the fee based on the rate and cost.

"""
function _getfee(fee_dict, cost=get_float(fee_dict, "cost"))
    rate = get_float(fee_dict, "rate")
    _feebysign(rate, cost)
end

@doc """ Determines the fee cost based on the currency

$(TYPEDSIGNATURES)

This function determines the fee cost based on the currency specified in the fee dictionary.
If the currency matches the quote currency, it returns the fee in quote currency.
If the currency matches the base currency, it returns the fee in base currency.
If the currency doesn't match either, it returns zero for both.

"""
function _feecost(
    fee_dict, ai, ::EIDType=exchangeid(ai); qc_py=@pystr(qc(ai)), bc_py=@pystr(bc(ai))
)
    cur = get_py(fee_dict, "currency")
    @debug "live fee cost" _module = LogCreateTrade cur qc_py bc_py
    if pyeq(Bool, cur, qc_py)
        @debug "live fee cost: quote currency" _module = LogCreateTrade _getfee(fee_dict)
        (_getfee(fee_dict), 0.0)
    elseif pyeq(Bool, cur, bc_py)
        @debug "live fee cost: base currency" _module = LogCreateTrade _getfee(fee_dict)
        (0.0, _getfee(fee_dict))
    else
        (0.0, 0.0)
    end
end

# This tries to always convert the fees in quote currency
# function _feecost_quote(s, ai, bc_price, date, qc_py=@pystr(qc(ai)), bc_py=@pystr(bc(ai)))
#     if pyeq(Bool, cur, bc_py)
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

@doc """ Determines the currency of the fee based on the order side

$(TYPEDSIGNATURES)

This function determines the currency of the fee based on the side of the order.
It uses the `feeSide` property of the market associated with the order.
The function returns `:base` if the fee is in the base currency and `:quote` if the fee is in the quote currency.

"""
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

@doc """ Calculates the default trade fees based on the order side

$(TYPEDSIGNATURES)

This function calculates the default trade fees based on the side of the order and the current market conditions.
It uses the `trade_feecur` function to determine the currency of the fee and then calculates the fee based on the amount and cost of the trade.

"""
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
@doc """ Determines the trade fees based on the response and side of the order

$(TYPEDSIGNATURES)

This function determines the trade fees based on the response from the exchange and the side of the order.
It first checks if the response contains a fee dictionary. If it does, it calculates the fee cost based on the dictionary.
If the response does not contain a fee dictionary but contains a list of fees, it calculates the total fee cost from the list.
If the response does not contain either, it calculates the default trade fees.

"""
function _tradefees(resp, side, ai; actual_amount, net_cost)
    eid = exchangeid(ai)
    v = resp_trade_fee(resp, eid)
    if pyisinstance(v, pybuiltins.dict)
        @debug "live trade fees: " _module = LogCreateTrade _feecost(v, ai, eid)
        return _feecost(v, ai, eid)
    end
    v = resp_trade_fees(resp, eid)
    fees_quote, fees_base = 0.0, 0.0
    if pyisinstance(v, pybuiltins.list) && !isempty(v)
        qc_py = @pystr(qc(ai))
        bc_py = @pystr(bc(ai))
        for fee in v
            (q, b) = _feecost(fee, ai, eid; qc_py, bc_py)
            fees_quote += q
            fees_base += b
        end
    end
    if iszero(fees_quote) && iszero(fees_base)
        (fees_quote, fees_base) = _default_trade_fees(
            ai, side; fees_base, fees_quote, actual_amount, net_cost
        )
    end
    @debug "live trade fees" _module = LogCreateTrade fees_quote fees_base
    return (fees_quote, fees_base)
end

_addfees(net_cost, fees_quote, ::IncreaseOrder) = net_cost + fees_quote
_addfees(net_cost, fees_quote, ::ReduceOrder) = net_cost - fees_quote

@doc """ Checks if the trade symbol matches the order symbol

$(TYPEDSIGNATURES)

This function checks if the trade symbol from the response matches the symbol of the order.
If they do not match, it issues a warning and returns `false`.

"""
function isordersymbol(ai, o, resp, eid::EIDType; getter=resp_trade_symbol)::Bool
    pyeq(Bool, getter(resp, eid), @pystr(raw(ai))) || begin
        @warn "Mismatching trade for $(raw(ai))($(resp_trade_symbol(resp, eid))), order: $(o.asset), refusing construction."
        return false
    end
end

@doc """ Checks if the response is of the expected type

$(TYPEDSIGNATURES)

This function checks if the response from the exchange is of the expected type.
If the response is not of the expected type, it issues a warning and returns `false`.

"""
function isordertype(ai, o, resp, ::EIDType; type=pybuiltins.dict)::Bool
    if !pyisinstance(resp, type)
        @warn "Invalid response for order $(raw(ai)), order: $o, refusing construction."
        false
    else
        true
    end
end

@doc """ Checks if the trade id matches the order id

$(TYPEDSIGNATURES)

This function checks if the trade id from the response matches the id of the order.
If they do not match, it issues a warning and returns `false`.

"""
function isorderid(ai, o, resp, eid::EIDType; getter=resp_trade_order)::Bool
    if string(getter(resp, eid)) != o.id
        @warn "Mismatching id $(raw(ai))($(resp_trade_order(resp, eid))), order: $(o.id), refusing construction."
        false
    else
        true
    end
end

@doc """ Checks if the trade side matches the order side

$(TYPEDSIGNATURES)

This function checks if the side of the trade from the response matches the side of the order.
If they do not match, it issues a warning and returns `false`.

"""
function isorderside(side, o)::Bool
    if side != orderside(o)
        @warn "Mismatching trade side $side and order side $(orderside(o)), refusing construction."
        false
    else
        true
    end
end

function divergentprice(o::AnyMarketOrder, actual_price)
    false
end

function divergentprice(o::AnyBuyOrder, actual_price; rtol=0.05)
    !isapprox(actual_price, o.price; rtol) && actual_price > o.price
end

function divergentprice(o::AnySellOrder, actual_price; rtol=0.05)
    !isapprox(actual_price, o.price; rtol) && actual_price < o.price
end

@doc """ Checks if the trade price is valid

$(TYPEDSIGNATURES)

This function checks if the trade price from the response is approximately equal to the order price or if the order is a market order.
If the price is far off from the order price, it issues a warning.
The function also checks if the price is greater than zero, issuing a warning and returning `false` if it's not.

"""
function isorderprice(s, ai, actual_price, o; rtol=0.05, resp)::Bool
    if divergentprice(o, actual_price; rtol)
        @warn "create trade: trade price far off from order price" o.price exc_price =
            actual_price ai nameof(s) o o.id @caller(20)
        false
    elseif actual_price <= 0.0 || !isfinite(actual_price)
        @warn "create trade: invalid price" nameof(s) ai tradeid = resp_trade_id(
            resp, exchangeid(ai)
        ) o
        false
    else
        true
    end
end

@doc """ Checks if the trade amount is valid

$(TYPEDSIGNATURES)

This function checks if the trade amount from the response is greater than zero.
If it's not, it issues a warning and returns `false`.

"""
function isorderamount(s, ai, actual_amount; resp)::Bool
    if actual_amount <= 0.0 || !isfinite(actual_amount)
        @warn "create trade: invalid amount" nameof(s) ai tradeid = resp_trade_id(
            resp, exchangeid(ai)
        )
        false
    else
        true
    end
end

@doc """ Warns if the local cash is not enough for the trade

$(TYPEDSIGNATURES)

This function checks if the local cash is enough for the trade.
If it's not, it issues a warning.

"""
function _warn_cash(s, ai, o; actual_amount)
    if !iscashenough(s, ai, actual_amount, o)
        @warn "make trade: creating trade but local cash is not enough" cash(ai) o.id actual_amount
    end
end

@doc """ Constructs a trade based on the order and response

$(TYPEDSIGNATURES)

This function constructs a trade based on the order and the response from the exchange.
It performs several checks on the response, such as checking the type, symbol, id, side, price, and amount.
If any of these checks fail, the function returns `nothing`.
Otherwise, it calculates the fees, warns if the local cash is not enough for the trade, and constructs the trade.

"""
function maketrade(s::LiveStrategy, o, ai; resp, trade::Option{Trade}=nothing, kwargs...)
    eid = exchangeid(ai)
    if trade isa Trade
        return trade
    end
    if !isordertype(ai, o, resp, eid) ||
        !isordersymbol(ai, o, resp, eid) ||
        !isorderid(ai, o, resp, eid)
        @debug "maketrade: failed" _module = LogCreateTrade ai isordertype(ai, o, resp, eid) isordersymbol(ai, o, resp, eid) isorderid(ai, o, resp, eid)
        return nothing
    end
    side = _ccxt_sidetype(resp, eid; o)
    if !isorderside(side, o)
        @debug "maketrade: wrong side" _module = LogCreateTrade ai side o
        return nothing
    end
    actual_amount = resp_trade_amount(resp, eid)
    actual_price = resp_trade_price(resp, eid)

    isorderprice(s, ai, actual_price, o; resp)
    inlimits(actual_price, ai, :price)

    if actual_amount <= 0.0 || !isfinite(actual_amount)
        @debug "make trade: amount value absent from trade or wrong ($actual_amount)), using cost." _module =
            LogCreateTrade ai actual_amount resp
        net_cost = resp_trade_cost(resp, eid)
        actual_amount = toprecision(net_cost / actual_price, ai.precision.amount)
        if !isorderamount(s, ai, actual_amount; resp)
            @debug "make trade: wrong amount" _module = LogCreateTrade ai actual_amount
            return nothing
        end
    else
        net_cost = let c = cost(actual_price, actual_amount)
            toprecision(c, ai.precision.price)
        end
    end
    inlimits(net_cost, ai, :cost)
    inlimits(actual_amount, ai, :amount)

    _warn_cash(s, ai, o; actual_amount)
    date = @something pytodate(resp, eid) now()

    fees_quote, fees_base = _tradefees(resp, side, ai; actual_amount, net_cost)
    size = _addfees(net_cost, fees_quote, o)

    @debug "Constructing trade" _module = LogCreateTrade cash = cash(ai, posside(o)) ai = raw(
        ai
    ) s = nameof(s)
    @maketrade
end
