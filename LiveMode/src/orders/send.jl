using .Executors.Instruments: freecash
using .Executors: @price!, @amount!
using .Python: pybool
using .Data: default_value

@doc "Represents a trigger order with fields for the order type, price, and trigger condition."
const TriggerOrderTuple = NamedTuple{(:type, :price, :trigger)}

@doc """ Converts a trigger order to a dictionary compatible with ccxt.

$(TYPEDSIGNATURES)

The function transforms the order type, price, and trigger price into a Python dictionary.
This dictionary is compatible with the ccxt cryptocurrency trading library.
"""
function trigger_dict(exc, v)
    out = pydict()
    out[@pyconst("type")] = _ccxtordertype(exc, v.type)
    out[@pyconst("price")] = pyconvert(Py, v.price)
    out[@pyconst("triggerPrice")] = pyconvert(Py, v.trigger)
    out
end

@doc """ Checks if there is enough free cash to execute an increase order.

$(TYPEDSIGNATURES)

The function compares the absolute value of free cash in the strategy to the absolute value of the required cash for the order, which is the product of the amount and price.
"""
function check_available_cash(s, ai, amount, price, o::Type{<:IncreaseOrder})
    @debug "check avl cash: inc" _module = LogState freecash(s) amount leverage(ai, posside(o))  abs(amount) * price / abs(leverage(ai, posside(o)))
    abs(freecash(s)) >= abs(amount) * price / abs(leverage(ai, posside(o)))
end

@doc """ Checks if there is enough free cash to execute a reduce order.

$(TYPEDSIGNATURES)

The function compares the absolute value of free cash in the asset instance to the absolute value of the required cash for the order, which is the amount.
"""
function check_available_cash(_, ai, amount, _, o::Type{<:ReduceOrder})
    abs(freecash(ai, posside(o))) >= abs(amount)
end

@doc """ Ensure margin mode on exchange matches asset margin mode.


"""
function ensure_marginmode(s::LiveStrategy, ai::MarginInstance)
    exc = exchange(ai)
    mm = marginmode(ai)
    last_mm = get(ai, :live_margin_mode, missing)
    if ismissing(last_mm) || last_mm != mm
        @debug "margin mode: updating" mm last_mm exc = nameof(exc)
        hedged = ishedged(ai)
        remote_mode = Symbol(string(typeof(mm)))
        return if marginmode!(exc, remote_mode, raw(ai); hedged)
            ai[:live_margin_mode] = mm
            event!(exc, MarginUpdated(Symbol(:margin_mode_set_, mm), s, position(ai, Long)))
            event!(
                exc, MarginUpdated(Symbol(:margin_mode_set_, mm), s, position(ai, Short))
            )
            true
        else
            false
        end
    end
    true
end

function ensure_marginmode(s::LiveStrategy, ai)
    true
end

function pygetorconvert!(params, k, v)
    this_v = get(params, k, nothing)
    if !isnothing(this_v)
        if !(this_v isa Py)
            params[k] = @py this_v
        end
    else
        params[k] = @py if v isa Type
            default_value(v)
        else
            v
        end
    end
end

# TODO: split into multiple functions according to order type
@doc """ Sends a live order and performs checks for sufficient cash and order features.

$(TYPEDSIGNATURES)

This function initiates a live order in the specified strategy and asset instance.
It first checks available cash and whether certain order features are supported.
It then sends the order to the exchange, retries if exceptions occur, and handles the response.
"""
function live_send_order(
    s::LiveStrategy,
    ai::AssetInstance,
    t::Type{<:Order}=GTCOrder{Buy},
    args...;
    skipchecks=false,
    amount,
    price=lastprice(s, ai, t),
    post_only=false,
    reduce_only=false,
    stop_price=nothing,
    profit_price=nothing,
    stop_loss::Option{TriggerOrderTuple}=nothing,
    take_profit::Option{TriggerOrderTuple}=nothing,
    trigger_price=nothing,
    trigger_direction=nothing,
    trailing_percent=nothing, # 1.0 == 1/100
    trailing_amount=nothing, # in quote currency
    trailing_trigger_price=nothing, # `price` is used if not set
    kwargs...,
)
    # sanitize amount (since asset cash can be negative and could be used as input)
    amount = abs(amount)
    if !isnothing(trailing_amount)
        trailing_amount = abs(trailing_amount)
    end
    # NOTE: this should not be needed, but some exchanges can be buggy
    # might be used in a specialized function for problematic exchanges
    # @price! ai stop_loss stop_price price profit_price take_profit
    # @amount! ai amount
    if !skipchecks
        if !check_available_cash(s, ai, amount, price, t)
            @warn "send order: not enough cash" this_cash = cash(ai, posside(t)) ai_comm = committed(
                ai, posside(t)
            ) ai_free = freecash(ai, posside(t)) strat_cash = cash(s) strat_comm = committed(
                s
            ) order_cash = amount t lev = leverage(ai, posside(t))
            return nothing
        end
        if !ensure_marginmode(s, ai)
            @warn "send order: margin mode mismatch" this_mm = marginmode(ai) exc = nameof(
                exchange(ai)
            ) reduce_only
            if !reduce_only
                return nothing
            end
        end
    end
    sym = raw(ai)
    exc = exchange(ai)
    side = _ccxtorderside(t)
    type = _ccxtordertype(exc, t)
    params = PyDict{Py,Py}(@pystr(k) => pyconvert(Py, v) for (k, v) in kwargs)
    tif = _ccxttif(exc, t)
    if !isempty(tif)
        tif_k = @pystr(time_in_force_key(exc))
        tif_v = @pystr(time_in_force_value(exc, asset(ai), tif))
        pygetorconvert!(params, tif_k, tif_v)
    end
    function supportmsg(feat)
        @warn "send order: not supported" feat exc = nameof(exc)
    end

    postOnly = @pyconst("postOnly")
    reduceOnly = @pyconst("reduceOnly")
    stopLoss = @pyconst("stopLoss")
    stopLossPrice = @pyconst("stopLossPrice")
    takeProfitPrice = @pyconst("takeProfitPrice")
    triggerPrice = @pyconst("triggerPrice")
    triggerDirection = @pyconst("triggerDirection")

    if has(exc, :createPostOnlyOrder)
        pygetorconvert!(params, postOnly, post_only)
    elseif pyisTrue(get(params, postOnly, false))
        supportmsg("post only")
        delete!(params, postOnly)
    end
    if s isa MarginStrategy
        if has(exc, :createReduceOnlyOrder)
            pygetorconvert!(params, reduceOnly, reduce_only)
        elseif pyisTrue(get(params, reduceOnly, false))
            supportmsg("reduce only")
            delete!(params, reduceOnly)
        end
    end
    if !isnothing(trigger_price)
        if has(exc, :createTriggerOrder)
            pygetorconvert!(params, triggerPrice, trigger_price)
            pygetorconvert!(
                params,
                triggerDirection,
                @something(
                    trigger_direction, ifelse(
                        # NOTE: strict equality
                        orderside(t) === Buy,
                        "below",
                        "above",
                    )
                )
            )
        elseif haskey(params, triggerPrice)
            supportmsg("trigger order")
            delete!(params, triggerPrice)
            delete!(params, triggerDirection)
        end
    end
    if !isnothing(stop_price)
        if has(exc, :createStopLossOrder)
            pygetorconvert!(params, stopLossPrice, stop_price)
        elseif haskey(params, stopLossPrice)
            supportmsg("stop loss order (close position)")
            delete!(params, stopLossPrice)
        end
    end
    if !isnothing(profit_price)
        if has(exc, :createTakeProfitOrder)
            pygetorconvert!(params, takeProfitPrice, profit_price)
        elseif haskey(params, takeProfitPrice)
            supportmsg("take profit order (close position)")
            delete!(params, takeProfitPrice)
        end
    end
    if !isnothing(stop_loss) && !isnothing(take_profit)
        if has(exc, :createOrderWithTakeProfitAndStopLoss)
            pygetorconvert!(params, stopLoss, stop_loss)
            pygetorconvert!(params, takeProfit, take_profit)
        elseif haskey(params, stopLoss) || haskey(params, takeProfit)
            supportmsg("conditional trigger order")
            delete!(params, stopLoss)
            delete!(params, takeProfit)
        end
    elseif !isnothing(stop_loss) || !isnothing(take_profit)
        @warn "send order: conditional trigger needs both stop_loss and take_profit input parameters"
    end
    trailing = if !isnothing(trailing_percent)
        if has(exc, :createTrailingPercentOrder)
            pygetorconvert!(params, trailingPercent, trailing_percent)
        else
            supportmsg("trailing percent order")
        end
    elseif !isnothing(trailing_amount)
        if has(exc, :createTrailingAmountOrder)
            pygetorconvert!(params, trailingAmount, trailing_amount)
        else
            supportmsg("trailing amount order")
        end
    end
    if !isnothing(trailing)
        if !isnothing(trailing_trigger_price)
            pygetorconvert!(params, trailingTriggerPrice, trailing_trigger_price)
        elseif !isnothing(trailing_trigger_amount)
            if !(price isa Number)
                @warn "send order: trailing amount order needs price input parameter" price
                price = lastprice(ai)
            end
            pygetorconvert!(params, trailingTriggerPrice, price)
        end
    end
    # start monitoring before sending the create request
    watch_orders!(s, ai)
    watch_trades!(s, ai)
    @debug "send order: create" _module = LogSendOrder sym type price amount side params
    inc_pending_orders!(ai)
    resp = nothing
    try
        resp = create_order(s, sym, args...; side, type, price, amount, params)
    finally
        return if isnothing(resp) || resp isa Exception
            @warn "send order: failed" sym ai exception = resp args params
            dec_pending_orders!(ai)
            resp
        elseif pyisnone(resp_order_id(resp, exchangeid(ai)))
            dec_pending_orders!(ai)
            nothing
        else
            resp
        end
    end
end
