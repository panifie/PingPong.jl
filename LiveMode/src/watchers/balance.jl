using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastpushed!, _lastpushed, _lastprocessed!, _lastprocessed, _lastcount!, _lastcount
@watcher_interface!
using .Exchanges: check_timeout
using .Exchanges.Python: @py
using .Lang: splitkws, withoutkws, safenotify, safewait

const CcxtBalanceVal = Val{:ccxt_balance_val}

@doc """ Sets up a watcher for CCXT balance.

$(TYPEDSIGNATURES)

This function sets up a watcher for balance in the CCXT library. The watcher keeps track of the balance and updates it as necessary.
"""
function ccxt_balance_watcher(
    s::Strategy;
    interval=Second(1),
    wid="ccxt_balance",
    buffer_capacity=10,
    start=true,
    params=LittleDict{Any,Any}(),
    kwargs...,
)
    exc = st.exchange(s)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    params["type"] = @pystr(lowercase(string(_balance_type(s))))
    _exc!(attrs, exc)
    attrs[:strategy] = s
    attrs[:iswatch] = @lget! s.attrs :is_watch_balance has(exc, :watchBalance)
    attrs[:func_kwargs] = (; params, kwargs...)
    attrs[:interval] = interval
    _tfunc!(attrs, _w_balance_func(s, attrs))
    watcher_type = Py
    wid = string(wid, "-", hash((exc.id, nameof(s))))
    watcher(
        watcher_type,
        wid,
        CcxtBalanceVal();
        start,
        load=false,
        flush=false,
        process=false,
        buffer_capacity,
        view_capacity=1,
        fetch_interval=interval,
        attrs,
    )
end

@doc """ Wraps a fetch balance function with a specified interval.

$(TYPEDSIGNATURES)

This function wraps a fetch balance function `s` with a specified `interval`. Additional keyword arguments `kwargs` are passed to the fetch balance function.
"""
function _w_balance_func(s, attrs)
    exc = exchange(s)
    timeout = throttle(s)
    interval = attrs[:interval]
    params, rest = _ccxt_balance_args(s, attrs[:func_kwargs])
    tasks = Task[]
    if attrs[:iswatch]
        init = Ref(true)
        buffer_size = attr(s, :live_buffer_size, 1000)
        s[:balance_channel] = channel = Ref(Channel{Any}(buffer_size))
        function process_bal!(w, v)
            if !isnothing(v)
                _dopush!(w, v; if_func=isdict)
            end
            if !isready(channel[])
                push!(tasks, @async process!(w))
            end
            filter!(!istaskdone, tasks)
        end
        function init_watch_func(w)
            v = @lock w fetch_balance(s; timeout, params, rest...)
            process_bal!(w, v)
            init[] = false
            f_push(v) = put!(channel[], v)
            h = w[:balance_handler] = watch_balance_handler(exc; f_push, params, rest...)
            w[:process_tasks] = tasks
            start_handler!(h)
            bind(channel[], h.task)
        end
        function watch_balance_func(w)
            if init[]
                init_watch_func(w)
            end
            v = if isopen(channel[])
                take!(channel[])
            else
                channel[] = Channel{Any}(buffer_size)
                init_watch_func(w)
                if !isopen(channel[])
                    @error "Balance handler can't be started"
                    sleep(interval)
                else
                    take!(channel[])
                end
            end
            if v isa Exception
                @error "balance watcher: unexpected value" exception = v
                sleep(1)
            else
                process_bal!(w, pydict(v))
            end
        end
    else
        fetch_balance_func(w) = begin
            start = now()
            v = @lock w fetch_balance(s; timeout, params, rest...)
            _dopush!(w, v; if_func=isdict)
            push!(tasks, @async process!(w))
            filter!(!istaskdone, tasks)
            sleep_pad(start, interval)
        end
    end
end

_balance_task!(w) = begin
    f = _tfunc(w)
    w[:balance_task] = @async while isstarted(w)
        try
            f(w)
            safenotify(w.beacon.fetch)
        catch e
            if e isa InterruptException
                break
            else
                @debug_backtrace LogWatchPos2
            end
        end
    end
end

_balance_task(w) = @lget! attrs(w) :balance_task _balance_task!(w)

function Watchers._stop!(w::Watcher, ::CcxtBalanceVal)
    s = w[:strategy]
    handler = attr(w, :balance_handler, nothing)
    if !isnothing(handler)
        stop_handler!(handler)
    end
    channel = attr(s, :balance_channel, nothing)
    if channel isa Ref{Channel} && isopen(channel[])
        close(channel[])
    end
    nothing
end

function Watchers._fetch!(w::Watcher, ::CcxtBalanceVal)
    fetch_task = _balance_task(w)
    if !istaskrunning(fetch_task)
        _balance_task!(w)
    end
    return true
end

@doc """ A named tuple of total, free, and used balances. """
const BalanceTuple = NamedTuple{(:total, :free, :used),NTuple{3,DFT}}
@doc """ A snapshot of total, free, and used balances. """
const BalanceSnapshot = NamedTuple{(:date, :balance),Tuple{DateTime,BalanceTuple}}
@doc """ A dictionary of balances. """
const BalanceDict1 = Dict{Symbol,BalanceTuple}
@doc """ A snapshot of balances. """
const BalanceView2 = NamedTuple{(:date, :balance),Tuple{Ref{DateTime},BalanceDict1}}

function _init!(w::Watcher, ::CcxtBalanceVal)
    dataview = (; date=Ref(DateTime(0)), balance=BalanceDict1())
    default_init(w, dataview, false)
    _lastpushed!(w, DateTime(0))
    _lastprocessed!(w, DateTime(0))
    _lastcount!(w, ())
end

@doc """ Processes balance for a watcher using the CCXT library.

$(TYPEDSIGNATURES)

This function processes balance for a watcher `w` using the CCXT library. It goes through the balance stored in the watcher and updates it based on the latest data from the exchange.

"""
function Watchers._process!(w::Watcher, ::CcxtBalanceVal; fetched=false)
    if isempty(w.buffer)
        return nothing
    end
    eid = typeof(exchangeid(_exc(w)))
    data_date, data = last(w.buffer)
    bal = w.view.balance
    if !isdict(data) || resp_event_type(data, eid) != ot.Balance
        @debug "watchers process: wrong data type" _module = LogWatchBalProcess data_date typeof(data)
        _lastprocessed!(w, data_date)
        _lastcount!(w, ())
    end
    if data_date == _lastprocessed(w) && length(data) == _lastcount(w)
        @debug "watchers process: already processed" _module = LogWatchBalProcess data_date
        return nothing
    end
    date = @something pytodate(data, eid) now()
    if date == w.view.date[]
        _lastprocessed!(w, data_date)
        return nothing
    end
    s = w[:strategy]
    assets_value = current_total(s) - s.cash
    qc_upper, qc_lower = @lget! attrs(w) :qc_syms begin
        upper = nameof(cash(s))
        lower = string(upper) |> lowercase |> Symbol
        upper, lower
    end
    for (sym, sym_bal) in data.items()
        if isdict(sym_bal) && haskey(sym_bal, @pyconst("free"))
            k = Symbol(sym)
            total = get_float(sym_bal, "total")
            free = let v = get_float(sym_bal, "free")
                if iszero(v)
                    max(zero(total), total - assets_value)
                else
                    v
                end
            end
            isqc = k == qc_upper || k == qc_lower
            used = let v = get_float(sym_bal, "used")
                if iszero(v)
                    used = v
                    ai = asset_bysym(s, string(sym))
                    # TODO: add fees?
                    if isqc
                        for o in orders(s)
                            if o isa IncreaseOrder
                                used += unfilled(o) * o.price
                            end
                        end
                    elseif !isnothing(ai)
                        for o in orders(s, ai)
                            if o isa ReduceOrder
                                used += unfilled(o)
                            end
                        end
                    end
                    used
                else
                    v
                end
            end
            balance = bal[k] = (; total, free, used)
            if isqc
                live_sync_strategy_cash!(s, bal=(; date, balance))
            end
            if s isa NoMarginStrategy
                live_sync_cash!(s, asset_bysym(s, sym), bal=(; date, balance))
            end
        end
    end
    w.view.date[] = date
    _lastprocessed!(w, data_date)
    _lastcount!(w, data)
    @debug "balance watcher data:" _module = LogWatchBalProcess date get(bal, :BTC, nothing) _module = :Watchers
end

@doc """ Starts a watcher for balance in a live strategy.

$(TYPEDSIGNATURES)

This function starts a watcher for balance in a live strategy `s`. The watcher checks and updates the balance at a specified interval.

"""
function watch_balance!(s::LiveStrategy; interval=st.throttle(s))
    @lock s begin
        w = @lget! attrs(s) :live_balance_watcher ccxt_balance_watcher(s; interval, start=true)
        @lock w if isstopped(w) && !attr(s, :stopping, false)
            start!(w)
        end
        w
    end
end

@doc """ Stops the watcher for balance in a live strategy.

$(TYPEDSIGNATURES)

This function stops the watcher that is tracking and updating balance for a live strategy `s`.

"""
function stop_watch_balance!(s::LiveStrategy)
    w = get(s.attrs, :live_balance_watcher, nothing)
    if w isa Watcher
        @lock w if isstarted(w)
            stop!(w)
        end
    end
end

@doc """ Retrieves the balance watcher for a live strategy.

$(TYPEDSIGNATURES)
"""
balance_watcher(s) = s[:live_balance_watcher]

# function _load!(w::Watcher, ::CcxtBalanceVal) end

# function _process!(w::Watcher, ::CcxtBalanceVal) end

function _start!(w::Watcher, ::CcxtBalanceVal)
    attrs = w.attrs
    s = attrs[:strategy]
    exc = exchange(s)
    _exc!(attrs, exc)
    _tfunc!(attrs, _w_balance_func(s, attrs))
end
