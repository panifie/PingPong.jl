using PythonCall: PyException, Py, pyisnull, PyDict, PyList, pyconvert
using Backtest: config
using Backtest.Data: zi, load_pair, is_last_complete_candle, save_pair, cleanup_ohlcv_data
using Backtest.Misc: _from_to_dt, PairData, default_data_path, _instantiate_workers, tfperiod, ContiguityException, isless, ohlcv_limits
using Backtest.Exchanges: Exchange, get_pairlist, py_except_name
@debug using Backtest.Misc: dt
using Backtest.Misc.Pbar
using Dates: now, Year, Millisecond
using Distributed: @distributed

function _fetch_one_pair(exc, zi, pair, timeframe; from="", to="", params=PyDict(), sleep_t=1, cleanup=true)
    from = timefloat(from)
    if to === ""
        to = now() |> timefloat
    else
        to = timefloat(to)
        from > to && @error "End date ($(to |> dt)) must be higher than start date ($(from |> dt))."
    end
    @debug "Fetching pair $pair from exchange $(exc.name) at $timeframe - from: $(from |> dt) - to: $(to |> dt)."
    data = _fetch_pair(exc, zi, pair, timeframe; from, to, params, sleep_t)
    if cleanup cleanup_ohlcv_data(data, timeframe) else data end
end

function find_since(exc, pair)
    tfs = collect(exc.timeframes)
    long_tf = tfs[findmax(tfperiod.(tfs))[2]]
    old_ts = Day(365) |> Millisecond |> timefloat |> Int
    # fetch the first available candles using a long (1w) timeframe
    data = _fetch_with_delay(exc, pair, long_tf; since=old_ts, df=true)
    if isempty(data)
        # try without `since` arg
        data = _fetch_with_delay(exc, pair, long_tf; df=true)
    end
    isempty(data) && return 0
    data[begin, 1] |> timefloat |> Int
end

function _fetch_pair(exc, zi, pair, timeframe; from::AbstractFloat, to::AbstractFloat, params, sleep_t)
    @as_td
    @debug "Downloading candles for pair $pair."
    pair ∉ keys(exc.markets) && throw("Pair $pair not in exchange markets.")
    data = _empty_df()
    local since
    if from === 0.0
        since = find_since(exc, pair)
    else
        append!(data, _fetch_with_delay(exc, pair, timeframe; since=Int(from), params, df=true))
        if size(data, 1) > 0
            since = data[end, 1] |> timefloat |> Int
        else
            @debug "Couldn't fetch candles for $pair from $(exc.name), too long dates? $(dt(from))."
            since = find_since(exc, pair)
        end
    end
    @debug "Starting from $(dt(since)) - to: $(dt(to))."
    while since < to
        sleep(sleep_t)
        fetched = _fetch_with_delay(exc, pair, timeframe; since, params, df=true)
        size(fetched, 1) === 0 && break
        append!(data, fetched)
        last_ts = timefloat(data[end, 1]) |> Int
        since === last_ts && break
        since = last_ts
        @debug "Downloaded candles for pair $pair up to $(since |> dt) from $(exc.name)."
    end
    return data
end

function _fetch_with_delay(exc, pair, timeframe; since=nothing, params=PyDict(), df=false, sleep_t=0, limit=nothing)
    try
        @debug "Calling into ccxt to fetch OHLCV data: $pair, $timeframe $since, $params"
        if isnothing(limit) limit = get(ohlcv_limits, Symbol(lowercase(string(exc.name))), 1000) end
        data = exc.fetchOHLCV(pair, timeframe; since, limit, params)
        dpl = Bool(@py data isa PyList)
        if !dpl
            @debug "Downloaded data is not a matrix...retrying (since: $(dt(since)))."
            sleep(sleep_t)
            sleep_t = (sleep_t + 1) * 2
            data = _fetch_with_delay(exc, pair, timeframe; since, params, sleep_t, df, limit=(limit ÷ 2))
        end
        if dpl && !isempty(data)
            data = reduce(hcat,
                          pyconvert(Vector{<:Vector}, data)) |> permutedims
        else
            data = []
        end
        size(data, 1) === 0 && return df ? _empty_df() : data
        @debug "Returning converted ohlcv data."
        df ? to_df(data) : data
    catch e
        if e isa PyException
            if !isnothing(match(r"429([0]+)?", string(e._v)))
                @debug "Exchange error 429, too many requests."
                sleep(sleep_t)
                sleep_t = (sleep_t + 1) * 2
                limit = isnothing(limit) ? limit : limit ÷ 2
                _fetch_with_delay(exc, pair, timeframe; since, params, sleep_t, df, limit)
            elseif py_except_name(e) ∈ ccxt_errors
                @warn "Error downloading ohlc data for pair $pair on exchange $(exc.name). \n $(e._v)"
                return df ? _empty_df() : []
            else
                rethrow(e)
            end
        else
            rethrow(e)
        end
    end
end

# FIXME: we assume the exchange class is set (is not pynull), if itsn't set PythonCall segfaults
function fetch_pairs(exc::Exchange, timeframe::AbstractString, pairs::StrOrVec; kwargs...)
    pairs = pairs isa String ? [pairs] : pairs
    fetch_pairs(exc, timeframe, pairs; kwargs...)
end

function fetch_pairs(timeframe::AbstractString, pairs::StrOrVec; kwargs...)
    fetch_pairs(exc, timeframe, pairs; kwargs...)
end

function fetch_pairs(exc::Exchange, timeframe::AbstractString; qc, kwargs...)
    pairs = get_pairlist(exc, qc; as_vec=true)
    fetch_pairs(exc, timeframe, pairs; kwargs...)
end

function fetch_pairs(timeframe::AbstractString; kwargs...)
    qc = :qc ∈ keys(kwargs) ? kwargs[:qc] : config.qc
    pairs = get_pairlist(exc, qc) |> keys |> collect
    fetch_pairs(timeframe, pairs; filter(x -> x[1] !== :qc, kwargs)...)
end

function fetch_pairs(::Val{:ask}, args...; kwargs...)
    Base.display("fetch? Y/n")
    ans = String(read(stdin, 1))
    ans ∉ ("\n", "y", "Y") && return
    fetch_pairs(args...; qc=config.qc, zi, kwargs...)
end

macro parallel(flag, body)
    b = esc(body)
    db = esc(:(@distributed $body))
    quote
        if $(esc(flag))
            $db
        else
            $b
        end
    end
end


@doc """ Fetch ohlcv data for multiple exchanges on the same timeframe.
It accepts:
    - a mapping of exchange instances to pairlists.
    - a vector of symbols for which an exchange instance will be instantiated for each element,
      and pairlist will be composed according to quote currency and min_volume from `Backtest.config`.
"""
function fetch_pairs(excs::Vector, timeframe; parallel=false, wait_task=false, kwargs...)
    # out_file = joinpath(default_data_path, "out.log")
    # err_file = joinpath(default_data_path, "err.log")
    # FIXME: find out how io redirection interacts with distributed
    # t = redirect_stdio(; stdout=out_file, stderr=err_file) do
    parallel && _instantiate_workers(:Backtest; num=length(excs))
    # NOTE: The python classes have to be instantiated inside the worker processes
    if eltype(excs) === Symbol
        e_pl = s -> (ex = Exchange(s); (ex, get_pairlist(ex; as_vec=true)))
    else
        e_pl = s -> (Exchange(Symbol(lowercase(s[1].name))), s[2])
    end
    t = @parallel parallel for s in excs
        ex, pl = e_pl(s)
        fetch_pairs(ex, timeframe, pl; kwargs...)
    end
    # end
    parallel && wait_task && wait(t)
    t
end

function fetch_pairs(exc::Exchange, timeframe::AbstractString, pairs::AbstractVector; zi=zi,
                     from::DateType="", to::DateType="", update=false, reset=false, progress=true)
    @assert exc.isset
    exc_name = exc.name
    local za
    if !is_timeframe_supported(timeframe, exc)
        @error "Timeframe $timeframe not supported by exchange $exc_name."
    end
    from, to = _from_to_dt(timeframe, from, to)
    if update
        if !isempty(string(from)) || !isempty(string(to))
            @warn "Don't set the `from` or `to` date if updating existing data."
        end
        reset && @warn "Ignoring reset since, update flag is true."
        # this fetches the last date stored
        from_date = (pair) -> begin
            za, (_, stop) = load_pair(zi, exc_name, pair, timeframe; as_z=true)
            za, size(za, 1) > 1 ? za[stop, 1] : from
        end
    else
        from_date = (_) -> (nothing, from)
    end
    data = Dict{String, PairData}()
    @info "Downloading data for $(length(pairs)) pairs."
    progress && @pbar! pairs "Pairlist download progress" "pair" false
    for name in pairs
        @debug "Fetching pair $name."
        z, pair_from_date = from_date(name)
        @debug "...from date $pair_from_date"
        if !is_last_complete_candle(pair_from_date, timeframe)
            ohlcv =  _fetch_one_pair(exc, zi, name, timeframe; from=pair_from_date, to)
        else
            ohlcv = _empty_df()
        end
        if size(ohlcv, 1) > 0
            try
                z = save_pair(zi, exc_name, name, timeframe, ohlcv; reset)
            catch e
                if e isa ContiguityException
                    z = save_pair(zi, exc_name, name, timeframe, ohlcv; reset=true)
                elseif e isa AssertionError
                    display(e)
                    @warn "Could not fetch data for pair $name, check integrity of saved data."
                else
                    rethrow(e)
                end
            end
        elseif isnothing(z)
            z, _ = load_pair(zi, exc_name, name, timeframe; as_z=true)
        end
        p = PairData(;name, tf=timeframe, data=ohlcv, z)
        data[name] = p
        @info "Fetched $(size(p.data, 1)) candles for $name from $(exc_name)"
        progress && @pbupdate!
    end
    progress && @pbclose
    data
end

export fetch_pairs
