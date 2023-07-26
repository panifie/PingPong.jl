using .Misc: LittleDict
using .Misc.Lang: @logerror
using .Instances.Exchanges: Py, pyfetch, @pystr, has
using SimMode: trade!
using .Executors: AnyGTCOrder

_asdate(py) = parse(DateTime, rstrip(string(py), 'Z'))

function paper_limitorder!(s::PaperStrategy, ai, o::GTCOrder)
    isfilled(ai, o) && return
    throttle = attr(s, :throttle)
    exc = ai.exchange
    pyfunc = getproperty(exc, first(exc, :watchTrades, :fetchTrades))
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
                                s, o, ai; price, date=_asdate(t["datetime"]), actual_amount, slippage=false
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
        catch e
            e isa InterruptException && break
            haskey(s.attrs, :logfile) && @logerror attr(s, :logfile)
            backoff += throttle
            sleep(backoff)
        end
        isopen(ai, o) || break
    end
    attr(s, :paper_order_tasks)[o] = (; task, alive)
end

function limitorder!(s, ai, t; amount, date, kwargs...)
    volumecap!(s, ai; amount) || return nothing
    o = create_sim_limit_order(s, t, ai; amount, date, kwargs...)
    isnothing(o) && return nothing
    try
        obside = orderbook_side(ai, t)
        trade = if !isempty(obside)
            _, _, trade = from_orderbook(obside, s, ai, o; o.amount, date)
            trade
        end
        # Queue GTC orders
        o isa AnyGTCOrder && paper_limitorder!(s, ai, o)
        # return first trade (if any)
        trade
    catch e
        !isfilled(ai, o) && cancel!(s, o, ai; err=OrderFailed(e))
    end
end
