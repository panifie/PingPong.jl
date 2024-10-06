using .Executors.Instruments: AbstractCash
using .Lang: @get
import .st: current_total
using .Exchanges: @tickers!, markettype
import .Exchanges: lastprice
import .Misc: reset!

@doc """ A named tuple of total, free, and used balances. """
mutable struct BalanceSnapshot{T<:AbstractFloat}
    const currency::Symbol
    date::DateTime
    total::T
    free::T
    used::T
    BalanceSnapshot{T}(args...) where {T} = new{T}(args...)
    function BalanceSnapshot(;
        total=0.0, free=0.0, used=0.0, currency=Symbol(), date=DateTime(0)
    )
        new{DFT}(Symbol(currency), date, total, free, used)
    end
    BalanceSnapshot(sym) = BalanceSnapshot(; currency=Symbol(sym))
    BalanceSnapshot(sym::Symbol) = BalanceSnapshot(; currency=sym)
    BalanceSnapshot(ai::AssetInstance) = BalanceSnapshot(bc(ai))
end

Base.zero(snap::BalanceSnapshot{T}) where {T} = BalanceSnapshot(snap.currency)

@doc """ A dictionary of balances. """
mutable struct BalanceDict{T}
    date::DateTime
    const assets::Dict{Symbol,BalanceSnapshot{T}}
    function BalanceDict{T}(
        date=DateTime(0), assets=Dict{Symbol,BalanceSnapshot{T}}()
    ) where {T}
        new{T}(date, assets)
    end
    BalanceDict(args...) = BalanceDict{DFT}(args...)
end

reset!(bal::BalanceSnapshot{T}) where {T} = begin
    bal.date = DateTime(0)
    bal.total = zero(T)
    bal.free = zero(T)
    bal.used = zero(T)
end
Base.getindex(bal::BalanceDict, sym::Symbol) = bal.assets[sym]
Base.getindex(bal::BalanceDict, ai::AssetInstance) = getindex(bal, bc(ai))
Base.getindex(bal::BalanceDict, c::AbstractCash) = getindex(bal, nameof(c))
Base.getindex(bal::BalanceDict, s::Strategy) = getindex(bal, s.cash)
Base.setindex!(bal::BalanceDict, sym::Symbol, v) = setindex!(bal.assets, sym, v)
Base.setindex!(bal::BalanceDict, ai::AssetInstance, v) = setindex!(bal, bc(ai), v)
Base.delete!(bal::BalanceDict, sym::Symbol) = delete!(bal.assets, sym)
Base.delete!(bal::BalanceDict, ai::AssetInstance) = delete!(bal, bc(ai))
Base.empty(::Type{<:BalanceDict{T}}) where {T} = BalanceDict{T}()
Base.empty!(bal::BalanceDict{T}) where {T} = empty!(bal.assets)
Base.keys(bal::BalanceDict) = keys(bal.assets)
Base.values(bal::BalanceDict) = values(bal.assets)
Base.pairs(bal::BalanceDict) = pairs(bal.assets)
Base.iterate(bal::BalanceDict, args...; kwargs...) = iterate(bal.assets, args...; kwargs...)
function Base.get(bal::BalanceDict, ai::AssetInstance, args...; kwargs...)
    get(bal.assets, bc(ai), args...; kwargs...)
end
Base.get(bal::BalanceDict, args...; kwargs...) = get(bal.assets, args...; kwargs...)
reset!(bal::BalanceDict{T}) where {T} = begin
    for snap in values(bal.assets)
        reset!(snap)
    end
    bal.date = DateTime(0)
    bal
end
function Base.similar(bal::BalanceDict{T}) where {T}
    BalanceDict{T}(
        DateTime(0), Dict{Symbol,BalanceSnapshot{T}}(zero(snap) for snap in bal.assets)
    )
end
update!(bal::BalanceSnapshot, date; total, free, used) = begin
    bal.date = date
    bal.total = total
    bal.free = free
    bal.used = used
    bal
end

_balance_bytype(_, ::Nothing) = nothing
_balance_bytype(::Nothing, ::Symbol) = nothing
_balance_bytype(v, sym) = getproperty(v, sym)
@doc """ Retrieves the balance of a strategy.

$(TYPEDSIGNATURES)

This function retrieves the balance associated with a strategy `s`. It achieves this by watching the balance with a specified interval and returning the view of the balance.

"""
get_balance(s) = watch_balance!(s; interval=st.throttle(s)).view
function get_balance(s, sym; fallback_kwargs=(;), bal=get_balance(s))
    if isnothing(bal) || sym ∉ keys(bal)
        if nameof(cash(s)) == sym || st.inuniverse(sym, s)
            _force_fetchbal(s; fallback_kwargs)
            bal = get_balance(s)
            @get bal sym BalanceSnapshot(sym)
        else
            BalanceSnapshot(sym)
        end
    else
        bal[sym]
    end
end
get_balance(s, sym, type; kwargs...) = begin
    @deassert type ∈ (:used, :total, :free, nothing)
    bal = get_balance(s, sym; kwargs...)
    if isnothing(type)
        bal
    else
        _balance_bytype(bal, type)
    end
end
get_balance(s, ::Nothing, ::Nothing) = get_balance(s, nothing)
function get_balance(s, ai::AssetInstance, tp::Option{Symbol}=nothing; kwargs...)
    get_balance(s, bc(ai), tp; kwargs...)
end
function get_balance(s, ::Nothing, args...; kwargs...)
    get_balance(s, nameof(cash(s)), args...; kwargs...)
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
function _force_fetchbal(s; fallback_kwargs, waitfor=Second(15))
    @timeout_start
    w = balance_watcher(s)
    last_time = lastdate(w)
    prev_bal = get_balance(s)

    function skip_if_updated()
        @debug "force fetch bal: checking if updated" _module = LogBalance islocked(w) f = @caller
        if _isupdated(w, prev_bal, last_time; this_v_func=() -> get_balance(s))
            @debug "force fetch bal: updated" _module = LogBalance islocked(w)
            waitsync(s; waitfor=@timeout_now)
            true
        else
            @debug "force fetch bal: not updated" _module = LogBalance islocked(w)
            false
        end
    end

    waitsync(s; waitfor=@timeout_now)
    skip_if_updated() && return nothing

    @debug "force fetch bal: locking watcher" _module = LogBalance
    resp, time = @lock w begin
        skip_if_updated() && return nothing
        time = now()
        params, rest = _ccxt_balance_args(s, fallback_kwargs)
        @debug "force fetch bal: fetching" _module = LogBalance
        resp = fetch_balance(s; params, rest...)
        _handle_bal_resp(resp), time
    end
    if !isnothing(resp)
        push!(w.buf_process, resp)
        notify(w.buf_notify)
        @debug "force fetch bal: processing" _module = LogBalance
        skip_if_updated() && return nothing
        waitsync(s; waitfor=@timeout_now)
    end
    @debug "force fetch bal: done" _module = LogBalance lastdate(w)
end

@doc """ Retrieves the live balance for a strategy.

$(TYPEDSIGNATURES)

The function `live_balance` retrieves the live balance for a given strategy `s` and asset `ai`.
If `force` is `true` and the balance watcher is not locked, it forces a balance fetch operation.
If the balance is not found or is outdated, it waits for a balance update or forces a balance fetch operation depending on the `force` parameter.
The function accepts additional parameters `fallback_kwargs` for the balance fetch operation.
If `ai=nothing` and `full=true` the dict of all assets balances will be returned, otherwise the `BalanceTuple` of the strategy cash currency.
"""
function live_balance(
    s::LiveStrategy,
    ai=nothing;
    fallback_kwargs=(),
    since=nothing,
    force=false,
    synced=false,
    waitfor=Second(5),
    drift=Millisecond(5),
    type=nothing,
    full=false,
)::Union{BalanceDict,BalanceSnapshot,Nothing}
    @timeout_start
    watch_balance!(s)
    bal_args = full ? () : (ai, type)
    getbal() = get_balance(s, bal_args...)
    waitw(waitfor=@timeout_now) = waitsync(@something(ai, s); since, waitfor)
    forcebal() = _force_fetchbal(s; fallback_kwargs)

    return if !isnothing(since)
        function waitsincefunc(bal=getbal())
            !isnothing(bal) && bal.date + drift >= since
        end
        waitforcond(waitsincefunc, @timeout_now())
        if @istimeout()
            @debug "live bal: since timeout" _module = LogBalance since waitfor
            if !waitsincefunc()
                if force
                    forcebal()
                    waitw()
                elseif synced
                    waitw()
                end
            end
            bal = getbal()
            if waitsincefunc(bal)
                bal
            end
        else
            getbal()
        end
    elseif force
        @debug "live bal: force fetching balance" _module = LogBalance ai
        forcebal()
        waitw()
        getbal()
    elseif synced
        waitw()
        getbal()
    else
        getbal()
    end
end

@doc """ Retrieves a specific kind of live balance.

$(TYPEDSIGNATURES)

The function `_live_kind` retrieves a specific kind of live balance for a given strategy `s` and asset `ai`.
The kind of balance to retrieve is specified by the `kind` parameter.
If the balance is not found, it returns a zero balance with the current date.
"""
function _live_kind(args...; kind, since=nothing, kwargs...)
    bal = live_balance(args...; since, kwargs...)
    if isnothing(bal)
        bal = BalanceSnapshot(@something(since, now()))
    end
    getproperty(bal, kind)
end

live_total(args...; kwargs...) = _live_kind(args...; kind=:total, kwargs...)
live_used(args...; kwargs...) = _live_kind(args...; kind=:used, kwargs...)
live_free(args...; kwargs...) = _live_kind(args...; kind=:free, kwargs...)

@doc """ Calculates the current total balance for a strategy.

$(TYPEDSIGNATURES)

The function `current_total` calculates the current total balance for a given strategy `s`.
It sums up the value of all assets in the universe of the strategy, using either the local balance or the fetched balance depending on the `local_bal` parameter.
The function accepts a `price_func` parameter to determine the price of each asset.
"""
function st.current_total(
    s::LiveStrategy{N,<:ExchangeID,<:WithMargin};
    price_func=lastprice,
    local_bal=false,
    bal::BalanceDict=get_balance(s),
) where {N}
    tot = Ref(zero(DFT))
    s_tot = if local_bal
        s.cash.value
    else
        cur = nameof(cash(s))
        (@get bal cur BalanceSnapshot(cur)).free
    end
    if !isfinite(s_tot)
        @warn "strategy cash: not finite value"
        s_tot = zero(s_tot)
    end
    @debug "total: loop" _module = LogTasks
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
            if isfinite(v)
                tot[] += v
            else
                @warn "strategy cash: not finite asset cash" ai = raw(ai) long = cash(
                    ai, Long
                ) short = cash(ai, Short)
            end
        end
    end
    @debug "total: loop done" _module = LogTasks
    tot[] + s_tot
end

@doc """ Calculates the total balance for a strategy.

$(TYPEDSIGNATURES)

This function computes the total balance for a given strategy `s` by summing up the value of all assets in the strategy's universe.
The balance can be either local or fetched depending on the `local_bal` parameter.
The `price_func` parameter is used to determine the price of each asset.
"""
function st.current_total(
    s::LiveStrategy{N,<:ExchangeID,NoMargin};
    price_func=lastprice,
    local_bal=false,
    bal::BalanceDict=get_balance(s),
) where {N}
    tot = if local_bal
        cash(s).value
    else
        @get(bal, s, BalanceSnapshot(nameof(s))).free
    end
    if !isfinite(tot)
        @warn "strategy cash: not finite"
        tot = zero(tot)
    end
    function wprice_func(ai)
        try
            price_func(ai)
        catch
            @warn "current total: price func failed" exc = nameof(exchange(s)) price_func
            @debug_backtrace
            zero(tot[])
        end
    end
    @sync for ai in s.universe
        @async let v = if local_bal
                cash(ai).value
            else
                (@get bal ai BalanceSnapshot(bc(ai))).free
            end * wprice_func(ai)
            # NOTE: `x += y` is rewritten as x = x + y
            # Because `price_func` can be async, the value of `x` might be stale by
            # the time `y` is fetched, and the assignment might clobber the most
            # recent value of `x`
            if isfinite(v)
                tot += v
            else
                @warn "strategy cash: not finite asset cash" ai = raw(ai)
            end
        end
    end
    tot
end
