const ExchangeOrderId = Py
const ExchangeTrade = Py
const MarketTrades = Dict{ExchangeOrderId,Vector{ExchangeTrade}}

function watch_trades!(s::LiveStrategy, ai; fetch_kwargs=())
    exc = exchange(ai)
    interval = st.attr(s, :throttle, Second(5))
    trades_by_order = markettrades(s, ai)
    task = @start_task trades_by_order begin
        f = if has(exc, :watchMyTrades)
            let sym = raw(ai), func = exc.watchMyTrades
                () -> pyfetch(func, sym; coro_running=pycoro_running())
            end
        else
            fetch_my_trades(s, ai; fetch_kwargs...)
            sleep(interval)
        end
        while istaskrunning()
            try
                while istaskrunning()
                    trades = f()
                    set_trades!(trades_by_order, trades)
                end
            catch
                @debug "trade watching for $(raw(ai)) resulted in an error (possibly a task termination through running flag)."
                sleep(1)
            end
        end
    end
    try
        market_tasks(s)[ai][:trades_task] = task
        task
    catch
        task
    end
end

tradestask(s, ai) = get(market_tasks(s)[ai], :trades_task, nothing)
function markettrades(s, ai)
    let markets = @lget! s.attrs :live_market_trades Dict{AssetInstance,MarketTrades}()
        @lget! markets ai MarketTrades()
    end
end

function set_trades!(out, trades)
    for t in trades
        id = get_py(t, "order")
        pyisTrue(@py id ∉ keys(out))
        if pyisnone(id)
            @warn "Missing order id"
            continue
        elseif pyisTrue(@py id ∉ keys(out))
            try
                trades = @lget! out id Vector{ExchangeTrade}()
                push!(trades, t)
            catch e
                @error e
            end
        end
    end
end
