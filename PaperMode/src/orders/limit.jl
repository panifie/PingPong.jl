using .Misc: LittleDict
using .Misc.Lang: @logerror, @debug_backtrace
using .Instances.Exchanges: Py, pyfetch, @pystr, @pyconst, has
using SimMode: trade!
using .Executors: AnyGTCOrder
using .OrderTypes: ImmediateOrderType, OrderCanceled

_asdate(py) = parse(DateTime, rstrip(string(py), 'Z'))

@doc """ Updates a limit order in PaperMode.

$(TYPEDSIGNATURES)

The function checks if the order is filled.
If not, it fetches the trades for the given asset and exchange.
It then checks each trade to see if the order is triggered.
If the order is triggered, it executes a trade for the minimum of the trade amount and the unfilled order amount.
If the order is filled, it stops tracking the order.

"""
function paper_limitorder!(s::PaperStrategy, ai, o::GTCOrder; kwargs...)
    isfilled(ai, o) && return nothing
    throttle = attr(s, :throttle)
    exc = ai.exchange
    pyfunc = first(exc, :watchTrades, :fetchTrades)
    sym = ai.asset.raw
    backoff = Second(0)
    alive = Ref(true)
    task = @async while alive[]
        try
            last_date = DateTime(0)
            trades = CircularBuffer{Py}(100)
            while alive[] && isopen(ai, o)
                append!(
                    trades,
                    pyfetch(
                        pyfunc,
                        sym;
                        since=ifelse(
                            last_date == DateTime(0),
                            nothing,
                            TimeTicks.timestamp(last_date + Millisecond(1)),
                        ),
                    ),
                )
                if isempty(trades)
                    sleep(throttle)
                    continue
                end
                this_date = _asdate(last(trades)["datetime"])::DateTime
                if last_date < this_date
                    last_date = this_date
                    for t in trades
                        price = pytofloat(t["price"])
                        if _istriggered(o, price)
                            actual_amount = min(pytofloat(t["amount"]), abs(unfilled(o)))
                            trade!(
                                s,
                                o,
                                ai;
                                price,
                                date=_asdate(t["datetime"]),
                                actual_amount,
                                slippage=false,
                                kwargs...,
                            )
                            isfilled(ai, o) && begin
                                alive[] = false
                                delete!(attr(s, :paper_order_tasks), o)
                                break
                            end
                        end
                    end
                    empty!(trades)
                end
                sleep(throttle)
            end
        catch
            e isa InterruptException && break
            @debug_backtrace
            backoff += throttle
            sleep(backoff)
        end
        isopen(ai, o) || break
    end
    attr(s, :paper_order_tasks)[o] = (; task, alive)
end

@doc """ Creates a limit order in PaperMode.

$(TYPEDSIGNATURES)

The function first checks if the order volume exceeds the daily limit using the `volumecap!` function.
If the volume is within the limit, it creates a simulated limit order using the `create_sim_limit_order` function.
If the order is not filled and is of type ImmediateOrderType, it cancels the order.
For Good Till Canceled (GTC) orders, it queues them for execution using the `paper_limitorder!` function.

"""
function create_paper_limit_order!(s, ai, t; amount, date, kwargs...)
    if volumecap!(s, ai; amount)
    else
        @debug "paper limit order: overcapacity" ai = raw(ai) amount liq = _paper_liquidity(
            s, ai
        )
        return nothing
    end
    fees_kwarg, order_kwargs = splitkws(:fees; kwargs)
    o = create_sim_limit_order(s, t, ai; amount, date, order_kwargs...)
    isnothing(o) && return nothing
    try
        obside = orderbook_side(ai, t)
        trade = if !isempty(obside)
            _, _, trade = from_orderbook(obside, s, ai, o; o.amount, date)
            @debug "paper limit order: trade from orderbook" o.asset o.price o.amount trade
            trade
        end
        # Queue GTC orders
        if o isa AnyGTCOrder
            @debug "paper limit order: queuing gtc order" o o.asset o.price o.amount
            paper_limitorder!(s, ai, o; fees_kwarg...)
            return @something trade missing
        elseif !isfilled(ai, o) && ordertype(o) <: ImmediateOrderType
            @debug "paper limit order: canceling" o.asset ordertype(o) o.price o.amount
            cancel!(s, o, ai; err=OrderCanceled(o))
        end
        # return first trade (if any)
        return trade
    catch
        @debug_backtrace
        !isfilled(ai, o) && cancel!(s, o, ai; err=OrderFailed(o))
        return missing
    end
end
