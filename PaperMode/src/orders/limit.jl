using .Misc: LittleDict
using .Misc.Lang: @logerror
using .Instances.Exchanges: Py, pyfetch, @pystr, has
using SimMode: trade!

_asdate(py) = parse(DateTime, rstrip(string(py), 'Z'))

function paper_limitorder!(s::PaperStrategy, ai, o::GTCOrder)
    throttle = attr(s, :throttle)
    exc = ai.exchange
    pyfunc = getproperty(exc, ifelse(has(exc, :watchTrades), :watchTrades, :fetchTrades))
    throttle = attr(s, :throttle)
    sym = ai.asset.raw
    backoff = Second(0)
    alive = Ref(true)
    task = @tspawnat 1 while alive[]
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
