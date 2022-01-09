
function _fetch_one_pair(exc, zi, pair, timeframe; from="", to="", params=Dict(), sleep_t=1, cleanup=true)
    from = timefloat(from)
    if to === ""
        to = Dates.now() |> timefloat
    else
        to = timefloat(to)
        from > to && @error "End date ($(to |> dt)) must be higher than start date ($(from |> dt))."
    end
    @debug "Fetching pair $pair from exchange $(exc.name) at $timeframe - from: $(from |> dt) - to: $(to |> dt)."
    data = _fetch_pair(exc, zi, pair, timeframe; from, to, params, sleep_t)
    if cleanup cleanup_ohlcv_data(data, timeframe) else data end
end

function find_since(exc, pair)
    long_tf = findmax(exc.timeframes)[2]
    # fetch the first available candles using a long (1w) timeframe
    _fetch_with_delay(exc, pair, long_tf; df=true)[begin, 1] |> timefloat |> Int
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
    while since < to
        sleep(sleep_t)
        fetched = _fetch_with_delay(exc, pair, timeframe; since, params, df=true)
        append!(data, fetched)
        last_ts = timefloat(data[end, 1]) |> Int
        since === last_ts && break
        since = last_ts
        @debug "Downloaded candles for pair $pair up to $(since |> dt) from $(exc.name)."
    end
    return data
end

function _fetch_with_delay(exc, pair, timeframe; since=nothing, params=Dict(), df=false, sleep_t=0)
    try
        data = exc.fetchOHLCV(pair, timeframe; since, params)
        if !(typeof(data) <: Array)
            @debug "Downloaded data is not a matrix...retrying (since: $(dt(since)))."
            sleep(sleep_t)
            sleep_t = (sleep_t + 1) * 2
            data = _fetch_with_delay(exc, pair, timeframe; since, params, sleep_t, df)
        end
        if data isa Matrix
            data = convert(Matrix{Float64}, data)
        else
            data = convert(Array{Float64}, data)
        end
        size(data, 1) === 0 && return df ? _empty_df() : data
        df ? to_df(data) : data
    catch e
        if e isa PyError && !isnothing(match(r"429([0]+)?", string(e.val)))
            @debug "Exchange error 429, too many requests."
            sleep(sleep_t)
            sleep_t = (sleep_t + 1) * 2
            _fetch_with_delay(exc, pair, timeframe; since, params, sleep_t, df)
        else
            rethrow(e)
        end
    end
end

function fetch_pairs(exc, timeframe::AbstractString, pairs::StrOrVec; kwargs...)
    pairs = pairs isa String ? [pairs] : pairs
    fetch_pairs(exc, timeframe, pairs; kwargs...)
end

function fetch_pairs(timeframe::AbstractString, pairs::StrOrVec; kwargs...)
    fetch_pairs(exc[], timeframe, pairs; kwargs...)
end

function fetch_pairs(exc::PyObject, timeframe::AbstractString; qc::AbstractString, kwargs...)
    pairs = get_pairlist(exc, qc)
    fetch_pairs(exc, timeframe, collect(keys(pairs)); kwargs...)
end

function fetch_pairs(::Val{:ask}, args...; kwargs...)
    Base.display("fetch? Y/n")
    ans = String(read(stdin, 1))
    ans ∉ ("\n", "y", "Y") && return
    fetch_pairs(args...; qc=options["quote"], zi, kwargs...)
end

function fetch_pairs(timeframe::AbstractString; kwargs...)
    fetch_pairs(exc[], timeframe; zi, qc=options["quote"], kwargs...)
end

function fetch_pairs(exc, timeframe::AbstractString, pairs::AbstractVector; zi=zi,
                     from::DateType="", to::DateType="", update=false, reset=false)
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
                z = save_pair(zi, exc.name, name, timeframe, ohlcv; reset)
            catch e
                if e isa ContiguityException
                    z = save_pair(zi, exc.name, name, timeframe, ohlcv; reset=true)
                else
                    rethrow(e)
                end
            end
        elseif isnothing(z)
            z = load_pair(zi, exc_name, name, timeframe; as_z=true)
        end
        p = PairData(;name, tf=timeframe, data=ohlcv, z)
        data[name] = p
        @info "Fetched $(size(p.data, 1)) candles for $name from $(exc.name)"
    end
    data
end

export fetch_pairs
