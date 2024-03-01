using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastfetched!, _lastfetched
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
    params[@pyconst("type")] = lowercase(string(_balance_type(s)))
    _exc!(attrs, exc)
    attrs[:strategy] = s
    attrs[:is_watch_func] = @lget! s.attrs :is_watch_balance has(exc, :watchBalance)
    attrs[:func_kwargs] = (; params, kwargs...)
    attrs[:interval] = interval
    _tfunc!(attrs, _w_fetch_balance_func(s, attrs))
    watcher_type = Py
    wid = string(wid, "-", hash((exc.id, nameof(s))))
    watcher(
        watcher_type,
        wid,
        CcxtBalanceVal();
        start,
        load=false,
        flush=false,
        process=true,
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
function _w_fetch_balance_func(s, attrs)
    exc = exchange(s)
    timeout = throttle(s)
    interval = attrs[:interval]
    params, rest = _ccxt_balance_args(s,  attrs[:func_kwargs])
    if attrs[:is_watch_func]
        init = Ref(true)
        (w) -> begin
            start = now()
            try
                if init[]
                    @lock w begin
                        v = fetch_balance_func(exc; timeout, params, reset...)
                        _dopush!(w, v; if_func=isdict)
                    end
                    init[] = false
                else
                    v = watch_balance_func(exc; params, rest...)
                    @lock w _dopush!(w, v; if_func=isdict)
                end
            catch
                @debug_backtrace LogWatchBalance
            end
            sleep_pad(start, interval)
        end
    else
        (w) -> begin
            start = now()
            try
                @lock w begin
                    v = fetch_balance_func(exc; timeout, params, rest...)
                    _dopush!(w, v; if_func=isdict)
                end
            catch
                @debug_backtrace LogWatchBalance
            end
            sleep_pad(start, interval)
        end
    end
end

_balance_task!(w) = begin
    f = _tfunc(w)
    w[:balance_task] = @async while isstarted(w)
        try
            f(w)
        catch
        end
        safenotify(w.beacon.fetch)
    end
end

_balance_task(w) = @lget! attrs(w) :balance_task _balance_task!(w)

function Watchers._fetch!(w::Watcher, ::CcxtBalanceVal)
    fetch_task = _balance_task(w)
    if !istaskrunning(fetch_task)
        _balance_task!(w)
    end
    s = w[:strategy]
    sync_task = strategy_task(s, attr(s, :account, "main"), :sync_cash)
    if !istaskrunning(sync_task)
        sync_balance_task!(s, w)
    end
    return true
end

@doc """ A named tuple of total, free, and used balances. """
const BalanceTuple = NamedTuple{(:total, :free, :used),NTuple{3,DFT}}
@doc """ A dictionary of balances. """
const BalanceDict1 = Dict{Symbol,BalanceTuple}
@doc """ A snapshot of balances. """
const BalanceView2 = NamedTuple{(:date, :balance),Tuple{Ref{DateTime},BalanceDict1}}

function _init!(w::Watcher, ::CcxtBalanceVal)
    dataview = (; date=Ref(DateTime(0)), balance=BalanceDict1())
    default_init(w, dataview, false)
    _lastfetched!(w, DateTime(0))
end

@doc """ Processes balance for a watcher using the CCXT library.

$(TYPEDSIGNATURES)

This function processes balance for a watcher `w` using the CCXT library. It goes through the balance stored in the watcher and updates it based on the latest data from the exchange.

"""
function Watchers._process!(w::Watcher, ::CcxtBalanceVal)
    if isempty(w.buffer)
        return nothing
    end
    _, update = last(w.buffer)
    bal = w.view.balance
    eid = typeof(exchangeid(_exc(w)))
    if !(isdict(update) && resp_event_type(update, eid) == ot.Balance)
        return nothing
    end
    date = @something pytodate(update, eid) now()
    if date == w.view.date[]
        return nothing
    end
    for (sym, sym_bal) in update.items()
        (isdict(sym_bal) && haskey(sym_bal, @pyconst("free"))) || continue
        k = Symbol(sym)
        bal[k] = (;
            total=get_float(sym_bal, "total"),
            free=get_float(sym_bal, "free"),
            used=get_float(sym_bal, "used"),
        )
    end
    w.view.date[] = date
    @debug "balance watcher update:" _module = LogWatchBalance date get(bal, :BTC, nothing) _module = :Watchers
    safenotify(w.beacon.process)
end

function sync_balance_task!(s, w; force=false)
    if force || isnothing(strategy_task(s, attr(s, :account, "main"), :sync_cash))
        t = @async begin
            kind = attr(s, :balance_kind, :free)
            while isstarted(w)
                safewait(w.beacon.process)
                live_sync_strategy_cash!(s, kind)
                if s isa NoMarginStrategy
                    live_sync_universe_cash!(s)
                end
            end
        end
        set_strategy_task!(s, "main", t, :sync_cash)
    end
end

@doc """ Starts a watcher for balance in a live strategy.

$(TYPEDSIGNATURES)

This function starts a watcher for balance in a live strategy `s`. The watcher checks and updates the balance at a specified interval.

"""
function watch_balance!(s::LiveStrategy; interval=st.throttle(s))
    @lock s @lget! attrs(s) :live_balance_watcher let w = ccxt_balance_watcher(s; interval, start=true)
        if isstopped(w)
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
    if w isa Watcher && isstarted(w)
        stop!(w)
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
    _tfunc!(attrs, _w_fetch_balance_func(s, attrs))
end

# function _stop!(w::Watcher, ::CcxtBalanceVal) end
