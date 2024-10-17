using Base: FieldDescStorage, swaprows!
const SignalType6 = @NamedTuple{
    type::UnionAll, tf::TimeFrame, count::Int, params::NamedTuple
}

struct Signals17{N}
    defs::LittleDict{Symbol,SignalType6}
    Signals17(; defs) = new{length(defs)}(defs)
end

@doc """
Create multiple signal definitions and instantiate a new `Signals17` object.

$(TYPEDSIGNATURES)

Constructs a dictionary of signals from input tuples and then creates a `Signals17` instance using these definitions. Each signal configuration is converted into a typed tuple preserving the structure required by `Signals17`.

"""
function signals(signals, timeframes, count, params)
    @assert length(signals) == length(timeframes) == length(count) == length(params) "every signal needs a timeframe and a period"
    names = ((sig.first for sig in signals)...,)::Tuple
    signals_tuple = (
        (
            (; type=sig.second, tf, count=c, params=p) for
            (sig, tf, c, p) in zip(signals, timeframes, count, params)
        )...,
    )
    defs = LittleDict(names, signals_tuple)
    Signals17(; defs)
end

function signals(defs::Vararg{Pair})
    Signals17(;
        defs=LittleDict(
            begin
                if !haskey(pair.second, :count)
                    count = max((i for i in values(pair.second.params) if i isa Integer)...)
                    pair.first => SignalType6((; pair.second..., count))
                else
                    pair
                end
            end

            for pair in defs
        ),
    )
end

@kwdef mutable struct SignalState4{T,V}
    date::DateTime = DateTime(0)
    trend::Trend = Stationary
    prev::V
    const state::T
end
function Base.iterate(state::StrategyTools.SignalState4)
    getfield(state, 1), 1
end

function Base.iterate(state::StrategyTools.SignalState4, prev)
    idx = prev + 1
    getfield(state, idx), idx
end

function signals_state!(s)
    sig_defs = s[:signals_def]
    s[:signals] = Dict(
        ai => begin
            NamedTuple(
                let
                    state = this.type(; this.params...)
                    state_tp = typeof(state)
                    prev_tp = fieldtype(state_tp, :value)
                    name => SignalState4{state_tp,prev_tp}(; state, prev=state.value)
                end for (name, this) in sig_defs.defs
            )
        end for ai in s.universe
    )
end

signals_names(s) = keys(s[:signals_def].defs)
signal_timeframe(s, name) = s[:signals_def].defs[name].tf
strategy_signal(s, ai, name) = s[:signals][ai][name]
@doc "Dispatch on `typeof(sig.state)`"
signal_value(::Any; sig) = sig.state.value
signal_value(s, ai, name) = begin
    sig = strategy_signal(s, ai, name)
    signal_value(sig.state; sig)
end
signal_trend(s, ai, name) = strategy_signal(s, ai, name).trend
signal_history(::Any; sig) = sig.prev

@doc """
Update or initialize mutable data related to asset information.

$(TYPEDSIGNATURES)

This function acquires or creates a data frame for the `ai` asset using the timeframe `tf`, then refreshes its OHLCV data by fetching new entries from the specified time onwards, based on the asset's symbol and exchange details. The update process may involve checking the existing data timestamps to avoid unnecessary data retrieval.
"""
function update_data!(ai, tf)
    df = @lget!(ai.data, tf, empty_ohlcv(ai, tf))
    from = isempty(df) ? now() - Day(1) : nothing
    update_ohlcv!(df, ai.symbol, ai.exc, tf; from)
end

@doc "Return the inputs for the `fit!` function of the signal."
function signal_range(sig, data, range)
    view(data.close, range)
end

@doc """
Update signal

$(TYPEDSIGNATURES)

Updates the signal `sig_name` for asset `ai` based on new data up to timestamp `ats`.
Uses a lookback window of `count` timeframes `tf`.
"""
function update_signal!(ai, ats, ai_signals, sig_name; tf, count)
    this = ai_signals[sig_name]
    data = ohlcv(ai, tf)
    this_tf_ats = available(tf, ats)
    @debug "update_signal!" raw(ai) iscontig = isempty(data) ? nothing : contiguous_ts(data) maxlog =
        1
    if ismissing(this.state.value)
        start_date = ats - tf * count
        idx_start = dateindex(data, start_date)
        if iszero(idx_start)
            @warn "can't update stat" ai = raw(ai) sig_name start_date maxlog = 1
            return nothing
        end
        idx_stop = dateindex(data, this_tf_ats)
        range = signal_range(this.state, data, idx_start:idx_stop)
        if length(range) < count
            @warn "not enough data for the requested count" start_date this_tf_ats count maxlog =
                1
        end
        @deassert idx_stop == idx_start + count ats, tf, count
        oti.fit!(this.state, range)
    elseif this.date < this_tf_ats
        # This ensures that we only compute the minimum necessary in case
        # the signals lags behind (only in live)
        start_date = max(this.date + tf, ats - tf * count)
        idx_start = dateindex(data, start_date)
        if iszero(idx_start)
            @warn "can't update stat" ai = raw(ai) sig_name start_date maxlog = 1
            return nothing
        end
        idx_stop = dateindex(data, this_tf_ats)
        @deassert data.timestamp[idx_stop] < apply(tf, ats)
        range = signal_range(this.state, data, idx_start:idx_stop)
        if !isempty(range)
            this.prev = this.state.value
            oti.fit!(this.state, range)
        else
            @warn "not enough data for the requested count" start_date this_tf_ats count maxlog =
                1
        end
    end
    this.date = this_tf_ats
end

@doc """
Update signals for a strategy.

$(TYPEDSIGNATURES)

Iterates over the universe of assets and for each asset iterates over the configured signals. Calls `update_signal!` to update each indicator with the current asset time series and configuration.
"""
function signals!(s::Strategy, ::Val{:warmup}; force=false, history=true)
    if force
        initparams!(s, getparams())
    elseif get!(s.attrs, :signals_set, false)
        return nothing
    end
    s[:signals] = signals_state!(s)
    # Fill fresh ohlcv data at startup
    if ispaper(s) || islive(s)
        for ai in s.universe
            this_asset = asset_tasks(ai).byname
            prev_task = get(this_asset, :signals, nothing)
            if !istaskrunning(prev_task)
                this_asset[:signals] = @async foreach(s.signals_def.defs) do def
                    update_data!(ai, def.tf)
                end
            end
        end
    end
    force && GC.gc()
    s[:signals_set] = true
end

@doc """
Update signals for a strategy.

$(TYPEDSIGNATURES)

Iterates over the universe of assets and for each asset iterates over the configured signals. Calls `update_signal!` to update each indicator with the current asset time series and configuration.
"""
function signals!(s::Strategy, ats, ::Val{:update})
    sigs = s[:signals]
    sigdefs = s[:signals_def]
    foreach(s.universe) do ai
        ai_signals = sigs[ai]
        foreach(sigdefs.defs) do (name, def)
            update_signal!(ai, ats, ai_signals, name; def.tf, def.count)
        end
    end
end
signals!(_) = nothing

@doc """
Update or initialize strategy signals.

$(TYPEDSIGNATURES)

Handles dynamic indicator updates based on strategy configurations. Redirects to `signals!` with appropriate value tagging and error management.
"""
signals!(s, args...; kwargs...) =
    try
        signals!(s, args...)
    catch
        @error "failed to load signals" args
        @debug_backtrace
        rethrow()
    end

function isstalesignal(s::Strategy, ats::DateTime; lifetime=0.25)
    any(
        ats - apply(sig_def.tf, ats) > sig_def.tf / (1.0 / lifetime) for
        sig_def in values(s.signals_def.defs)
    )
end
