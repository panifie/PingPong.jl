using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastfetched!, _lastfetched
@watcher_interface!
using .Exchanges: check_timeout
using .Exchanges.Python: @py
using .Lang: splitkws, withoutkws, safenotify, safewait

const CcxtBalanceVal = Val{:ccxt_balance_val}

@doc """ Wraps a fetch balance function with a specified interval.

$(TYPEDSIGNATURES)

This function wraps a fetch balance function `s` with a specified `interval`. Additional keyword arguments `kwargs` are passed to the fetch balance function.
"""
function _w_fetch_balance_func(s, interval; kwargs)
    exc = exchange(s)
    params, rest = _ccxt_balance_args(s, kwargs)
    fetch_f = first(exc, :fetchBalanceWs, :fetchBalance)
    if has(exc, :watchBalance)
        f = exc.watchBalance
        init = Ref(true)
        (w) -> try
            if init[]
                @lock w begin
                    v = _execfunc(fetch_f; params, rest...)
                    _dopush!(w, v; if_func=isdict)
                end
                init[] = false
                sleep(interval)
            else
                v = _execfunc(f; params, rest...)
                @lock w _dopush!(w, v; if_func=isdict)
            end
        catch
            @debug_backtrace
            sleep(1)
        end
    else
        (w) -> try
            @lock w begin
                v = _execfunc(fetch_f; params, rest...)
                _dopush!(w, v; if_func=isdict)
            end
            sleep(interval)
        catch
            @debug_backtrace
            sleep(interval)
        end
    end
end

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
    func_kwargs = (; params, kwargs...)
    _tfunc!(attrs, _w_fetch_balance_func(s, interval; kwargs=func_kwargs))
    _exc!(attrs, exc)
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

_balance_task!(w) = begin
    f = _tfunc(w)
    w[:balance_task] = @async while isstarted(w)
        f(w)
    end
end

_balance_task(w) = @lget! attrs(w) :balance_task _balance_task!(w)

function Watchers._fetch!(w::Watcher, ::CcxtBalanceVal)
    task = _balance_task(w)
    if !istaskstarted(task) || istaskdone(task)
        _balance_task!(w)
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
    isempty(w.buffer) && return nothing
    _, update = last(w.buffer)
    bal = w.view.balance
    isdict(update) || return nothing
    date = @something pytodate(update, typeof(exchangeid(_exc(w)))) now()
    date == w.view.date[] && return nothing
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
    @debug "balance watcher update:" date get(bal, :BTC, nothing)
    safenotify(w.beacon.process)
end

@doc """ Starts a watcher for balance in a live strategy.

$(TYPEDSIGNATURES)

This function starts a watcher for balance in a live strategy `s`. The watcher checks and updates the balance at a specified interval.

"""
function watch_balance!(s::LiveStrategy; interval=st.throttle(s))
    @lget! attrs(s) :live_balance_watcher ccxt_balance_watcher(s; interval, start=true)
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

# function _start!(w::Watcher, ::CcxtBalanceVal) end

# function _stop!(w::Watcher, ::CcxtBalanceVal) end
