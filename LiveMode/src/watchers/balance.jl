using Watchers
using Watchers: default_init
using Watchers.WatchersImpls: _tfunc!, _tfunc, _exc!, _exc, _lastfetched!, _lastfetched
@watcher_interface!
using .Exchanges: check_timeout
using .Exchanges.Python: @py
using .Lang: splitkws, safenotify, safewait

const CcxtBalanceVal = Val{:ccxt_balance_val}
function _w_fetch_balance_func(s, interval; kwargs)
    exc = exchange(s)
    params, rest = split_params(kwargs)
    if has(exc, :watchBalance)
        f = exc.watchBalance
        (w) -> try
            v = _execfunc(f; params, rest...)
            _dopush!(w, v; if_func=isdict)
        catch
        end
    else
        f = first(exc, :fetchBalanceWs, :fetchBalance)
        (w) -> try
            v = _execfunc(f; params, rest...)
            _dopush!(w, v; if_func=isdict)
            sleep(interval)
        catch
            sleep(interval)
        end
    end
end

function ccxt_balance_watcher(
    s::Strategy;
    interval=Second(5),
    wid="ccxt_balance",
    buffer_capacity=10,
    start=true,
    kwargs...,
)
    exc = st.exchange(s)
    check_timeout(exc, interval)
    attrs = Dict{Symbol,Any}()
    _tfunc!(attrs, _w_fetch_balance_func(s, interval; kwargs))
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
    @async while isstarted(w)
        f(w)
    end
end

_balance_task(w) = @lget! w.attrs :balance_task _balance_task!(w)

function Watchers._fetch!(w::Watcher, ::CcxtBalanceVal)
    task = _balance_task(w)
    if !istaskstarted(task) || istaskdone(task)
        _balance_task!(w)
    end
    return true
end

const BalanceTuple = NamedTuple{(:total, :free, :used),NTuple{3,DFT}}
const BalanceDict1 = Dict{Symbol,BalanceTuple}
const BalanceView2 = NamedTuple{(:date, :balance),Tuple{Ref{DateTime},BalanceDict1}}

function _init!(w::Watcher, ::CcxtBalanceVal)
    dataview = (; date=Ref(DateTime(0)), balance=BalanceDict1())
    default_init(w, dataview, false)
    _lastfetched!(w, DateTime(0))
end

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
end

function watch_balance!(s::LiveStrategy; interval=st.throttle(s))
    @lget! s.attrs :live_balance_watcher ccxt_balance_watcher(s; interval, start=true)
end

balance_watcher(s) = s[:live_balance_watcher]

# function _load!(w::Watcher, ::CcxtBalanceVal) end

# function _process!(w::Watcher, ::CcxtBalanceVal) end

# function _start!(w::Watcher, ::CcxtBalanceVal) end

# function _stop!(w::Watcher, ::CcxtBalanceVal) end
