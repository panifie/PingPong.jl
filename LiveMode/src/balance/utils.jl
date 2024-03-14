using .Executors.Instruments: AbstractCash
using .Lang: @get
import .st: current_total
using .Exchanges: @tickers!, markettype
import .Exchanges: lastprice

# FIXME: this should be handled by a `ccxt_balancetype` function
_balance_type(s::NoMarginStrategy) = :spot
_balance_type(s::MarginStrategy) = :swap

function _ccxt_balance_args(s, kwargs)
    params, rest = split_params(kwargs)
    @lget! params "type" @pystr(_balance_type(s))
    (; params, rest)
end

@doc """ Handles the response from a balance fetch operation.

$(TYPEDSIGNATURES)

The function `_handle_bal_resp` takes a response `resp` from a balance fetch operation.
If the response is a `PyException`, it returns `nothing`.
If the response is a dictionary, it returns the response as is.
For any other type of response, it logs an unhandled response message and returns `nothing`.
"""
function _handle_bal_resp(resp)
    if resp isa PyException
        @debug "force fetch bal: error" _module = LogBalance resp
        return nothing
    elseif isdict(resp)
        return resp
    else
        @debug "force fetch bal: unhandled response" _module = LogBalance resp
        return nothing
    end
end

@doc """ Forces a balance fetch operation.

$(TYPEDSIGNATURES)

The function `_force_fetchbal` forces a balance fetch operation for a given strategy `s`.
It locks the balance watcher `w` for the strategy, fetches the balance, and processes the response.
If the balance watcher is already locked, it returns `nothing`.
The function accepts additional parameters `fallback_kwargs` for the balance fetch operation.
"""
function _force_fetchbal(s; fallback_kwargs)
    w = balance_watcher(s)
    @debug "force fetch bal: locking w" _module = LogBalance islocked(w) f = @caller
    waslocked = islocked(w)
    last_time = lastdate(w)
    prev_bal = get_balance(s)

    if waslocked
        @debug "force fetch bal: waiting for fetch notify" _module = LogBalance
        wait(w)
        if _isupdated(w, prev_bal, last_time; this_v_func=() -> get_balance(s))
            @debug "force fetch bal: waited" _module = LogBalance
            return
        end
    end
    fetched = @lock w begin
        time = now()
        params, rest = _ccxt_balance_args(s, fallback_kwargs)
        resp = fetch_balance(s; params, rest...)
        bal = _handle_bal_resp(resp)
        if !isnothing(bal)
            pushnew!(w, bal, time)
            @debug "force fetch bal: processing" _module = LogBalance
            true
        else
            false
        end
    end::Bool
    if fetched
        process!(w)
    end
    @debug "force fetch bal: done" _module = LogBalance
end

@doc """ Waits for a balance update.

$(TYPEDSIGNATURES)

The function `waitforbal` waits for a balance update for a given strategy `s` and asset `ai`.
It checks the balance at intervals specified by `waitfor` until the balance is updated or a timeout occurs.
If the balance is not found and `force` is `true`, it forces a balance fetch operation.
The function accepts additional parameters `fallback_kwargs` for the balance fetch operation.
"""
function waitforbal(
    s::LiveStrategy,
    ai,
    args...;
    force=false,
    since=nothing,
    waitfor=Second(5),
    fallback_kwargs=(),
)
    timeout = Millisecond(waitfor).value
    slept = 0
    minsleep = Millisecond(max(Second(1), waitfor))
    bal = get_balance(s)
    if isnothing(bal) && force
        while true
            bal = get_balance(s, ai)
            isnothing(bal) || break
            slept < timeout || begin
                @debug "wait bal: timedout (balance not found)" _module = LogBalance ai = raw(ai) f = @caller
                return false
            end
            sleep(minsleep)
            slept += minsleep.value
            _force_fetchbal(s; fallback_kwargs)
        end
    end

    prev_timestamp = @something bal.date[] DateTime(0)
    prev_since = @something since typemin(DateTime)
    @debug "wait bal" _module = LogBalance prev_timestamp since
    if prev_timestamp >= prev_since
        return true
    end

    this_timestamp = prev_timestamp - Millisecond(1)
    w = balance_watcher(s)
    cond = w.beacon.process
    buf = buffer(w)
    @debug "wait bal: waiting" _module = LogBalance timeout = timeout
    while true
        slept += waitforcond(cond, timeout - slept)
        if length(buf) > 0
            this_timestamp = last(buf).time
        end
        if this_timestamp >= prev_timestamp >= prev_since
            @debug "wait bal: up to date " _module = LogBalance prev_timestamp this_timestamp
            return true
        else
            @debug "wait bal:" _module = LogBalance time_left = Millisecond(timeout - slept) prev_timestamp ai = raw(
                ai
            )
        end
        slept < timeout || begin
            @debug "wait bal: timedout (balance not changed)" ai = raw(ai) f = @caller
            return false
        end
    end
end

@doc """ Retrieves the live balance for a strategy.

$(TYPEDSIGNATURES)

The function `live_balance` retrieves the live balance for a given strategy `s` and asset `ai`.
If `force` is `true` and the balance watcher is not locked, it forces a balance fetch operation.
If the balance is not found or is outdated, it waits for a balance update or forces a balance fetch operation depending on the `force` parameter.
The function accepts additional parameters `fallback_kwargs` for the balance fetch operation.
"""
function live_balance(
    s::LiveStrategy,
    ai=nothing;
    fallback_kwargs=(),
    since=nothing,
    force=false,
    waitfor=Second(5),
    type=nothing,
)
    bal = get_balance(s, ai)
    wlocked = islocked(balance_watcher(s))
    if force &&
       !wlocked &&
       (isnothing(bal) || (!isnothing(since)) && bal.date < since)
        _force_fetchbal(s; fallback_kwargs)
        bal = get_balance(s, ai, type)
    end
    if (force && wlocked) ||
       !(isnothing(since) || isnothing(bal))
        if waitforbal(s, ai; since, force, waitfor, fallback_kwargs)
        else
            @debug "live bal: last force fetch"
            _force_fetchbal(s; fallback_kwargs)
        end
        bal = get_balance(s, ai, type)
        if isnothing(bal) || (!isnothing(since) && bal.date < since)
            @warn "live bal: no newer update" date = isnothing(bal) ? nothing : bal.date since f = @caller
        end
    end
    bal
end

@doc """ Retrieves a specific kind of live balance.

$(TYPEDSIGNATURES)

The function `_live_kind` retrieves a specific kind of live balance for a given strategy `s` and asset `ai`.
The kind of balance to retrieve is specified by the `kind` parameter.
If the balance is not found, it returns a zero balance with the current date.
"""
function _live_kind(args...; kind, kwargs...)
    bal = live_balance(args...; kwargs...)
    if isnothing(bal)
        bal = zerobal()
        bal.date[] = @something since now()
    end
    getproperty(bal.balance, kind)
end

live_total(args...; kwargs...) = _live_kind(args...; kind=:total, kwargs...)
live_used(args...; kwargs...) = _live_kind(args...; kind=:used, kwargs...)
live_free(args...; kwargs...) = _live_kind(args...; kind=:free, kwargs...)

_getbaldict(s) = get(something(get_balance(s), (;)), :balance, (;))
_getval(_) = ZERO
_getval(c::AbstractCash) = c.value
_getval(ai::AssetInstance) = _getval(cash(ai))
_getbal(bal, ai::AssetInstance) = get(bal, bc(ai), (;))
_getbal(bal, c) = get(bal, nameof(c), (;))
_getfree(bal, obj) = @get(_getbal(bal, obj), :free, _getval(obj))

@doc """ Calculates the current total balance for a strategy.

$(TYPEDSIGNATURES)

The function `current_total` calculates the current total balance for a given strategy `s`.
It sums up the value of all assets in the universe of the strategy, using either the local balance or the fetched balance depending on the `local_bal` parameter.
The function accepts a `price_func` parameter to determine the price of each asset.
"""
function st.current_total(
    s::LiveStrategy{N,<:ExchangeID,<:WithMargin}; price_func=lastprice, local_bal=false
) where {N}
    tot = Ref(zero(DFT))
    s_tot = if local_bal
        s.cash.value
    else
        _getfree(_getbaldict(s), cash(s))
    end
    @sync for ai in s.universe
        @async let v = if local_bal
                current_price = try
                    price_func(ai)
                catch
                    @debug_backtrace
                    if isopen(ai, Long())
                        entryprice(ai, Long())
                    elseif isopen(ai, Short())
                        entryprice(ai, Short())
                    else
                        zero(s_tot)
                    end
                end
                value(ai, Long(); current_price) + value(ai, Short(); current_price)
            else
                long_nt = abs(live_notional(s, ai, Long()))
                short_nt = abs(live_notional(s, ai, Short()))
                (long_nt - long_nt * maxfees(ai)) / leverage(ai, Long()) +
                (short_nt - short_nt * maxfees(ai)) / leverage(ai, Short())
            end
            tot[] += v
        end
    end
    tot[] + s_tot
end

@doc """ Calculates the total balance for a strategy.

$(TYPEDSIGNATURES)

This function computes the total balance for a given strategy `s` by summing up the value of all assets in the strategy's universe.
The balance can be either local or fetched depending on the `local_bal` parameter.
The `price_func` parameter is used to determine the price of each asset.
"""
function st.current_total(
    s::LiveStrategy{N,<:ExchangeID,NoMargin}; price_func=lastprice, local_bal=false
) where {N}
    tot = if local_bal
        cash(s).value
    else
        _getfree(_getbaldict(s), cash(s))
    end
    wprice_func(ai) =
        try
            price_func(ai)
        catch
            @warn "current total: price func failed" exc = nameof(exchange(s)) price_func
            @debug_backtrace
            zero(tot[])
        end
    @sync for ai in s.universe
        @async let v = if local_bal
                cash(ai).value
            else
                bal = _getbaldict(s)
                _getfree(bal, ai)
            end * wprice_func(ai)
            # NOTE: `x += y` is rewritten as x = x + y
            # Because `price_func` can be async, the value of `x` might be stale by
            # the time `y` is fetched, and the assignment might clobber the most
            # recent value of `x`
            tot += v
        end
    end
    tot
end
