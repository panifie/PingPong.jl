using DataFrames
using Tables
using Zarr: is_zarray

@doc "(Right)Merge two dataframes on key, assuming the key is ordered and unique in both dataframes."
function combinerows(df1, df2; idx::Symbol)
    # all columns
    columns = union(names(df1), names(df2))
    empty_tup2 = (;zip(Symbol.(names(df2)), Array{Missing}(missing, size(df2)[2]))...)
    l2 = size(df2)[1]

    c2 = 1
    i2 = df2[c2, idx]
    rows = []
    for (n, r1) in enumerate(Tables.namedtupleiterator(df1))
        i1 = getindex(r1, idx)
        if i1 < i2
            push!(rows, merge(empty_tup2, r1))
        elseif i1 === i2
            push!(rows, merge(r1, df2[c2, :]))
        elseif c2 < l2 # bring the df2 index to the df1 position
            c2 += 1
            i2 = df2[c2, idx]
            while i2 < i1 && c2 < l2
                c2 += 1
                i2 = df2[c2, idx]
            end
            i2 === i1 && push!(rows, merge(r1, df2[c2, :]))
        else # merge the rest of df1
            for rr1 in Tables.namedtupleiterator(df1[n:end, :])
                push!(rows, merge(empty_tup2, rr1))
            end
            break
        end
    end
    # merge the rest of df2
    if c2 < l2
        empty_tup1 = (;zip(Symbol.(names(df1)), Array{Missing}(missing, size(df1)[2]))...)
        for r2 in Tables.namedtupleiterator(df2[c2:end, :])
            push!(rows, merge(empty_tup1, r2))
        end
    end
    DataFrame(rows)
end

using TimeFrames: TimeFrame

macro zkey()
    p = esc(:pair)
    tf = esc(:timeframe)
    key = esc(:key)
    quote
        $key = joinpath($p, "ohlcv", "tf_" * $tf)
    end
    # joinpath("/", pair, "ohlcv", "tf_$timeframe")
end

function tfperiod(s::AbstractString)
    # convert m for minutes to T
    TimeFrame(replace(s, r"([0-9]+)m" => s"\1T")).period
end

function tfnum(prd::Dates.Period)
    convert(Dates.Millisecond, prd) |> x -> convert(Float64, x.value)
end

@doc """
`data_col`: the timestamp column of the new data (1)
`saved_col`: the timestamp column of the existing data (1)
`kind`: what type of trading data it is, (ohlcv or trades)
`pair`: the trading pair (BASE/QUOTE string)
`timeframe`: exchange timeframe (from exc.timeframes)
`type`: Primitive type used for storing the data (Float64)
"""
function _save(zi::ZarrInstance, pair, timeframe, data; kind="ohlcv", type=Float64, data_col=1, saved_col=1, overwrite=true, reset=false)
    @zkey
    prd = tfperiod(timeframe)
    td = tfnum(prd)
    local za
    local existing=true
    if is_zarray(zi.store, key)
        za = zopen(zi.store, "w"; path=key)
        if size(za, 2) !== size(data, 2)
            if overwrite
                rm(joinpath(zi.store.folder, key); recursive=true)
                za = zcreate(type, zi.store, size(data)...; path=key)
            else
                throw("Dimensions mismatch between stored data $(size(za)) and new data. $(size(data))")
            end
        else
            existing = true
        end
    else
        if !Zarr.isemptysub(zi.store, key)
            p = joinpath(zi.store.folder, key)
            @debug "Deleting garbage at path $p"
            rm(p; recursive=true)
        end
        za = zcreate(type, zi.store, size(data)...; path=key)
    end
    @debug "Zarr dataset for key $key, len: $(size(data))."
    if !reset && existing && size(za, 1) > 0
        local data_view
        saved_first_ts = za[1, saved_col]
        saved_last_ts = za[end, saved_col]
        data_first_ts = data[1, data_col]
        data_last_ts = data[end, data_col]
        _check_contiguity(data_first_ts, data_last_ts, saved_first_ts, saved_last_ts, td)
        # if appending data
        if data_first_ts >= saved_first_ts
            if overwrite
                # when overwriting get the index where data starts overwriting storage
                # we count the number of candles using the difference
                offset = convert(Int, ((data_first_ts - saved_first_ts + td) ÷ td))
                data_view = @view data[:, :]
                @debug dt(data_first_ts), dt(saved_last_ts), dt(saved_last_ts + td)
                @debug :saved, dt.(za[end, saved_col]) :data, dt.(data[1, data_col]) :saved_off, dt(za[offset, data_col])
                @assert data[1, data_col] === za[offset, saved_col]
            else
                # when not overwriting get the index where data has new values
                data_offset = searchsortedlast(data[:, data_col], saved_last_ts) + 1
                offset = size(za, 1) + 1
                if data_offset <= size(data, 1)
                    data_view = @view data[data_offset:end, :]
                    @debug :saved, dt(za[end, saved_col]) :data_new, dt(data[data_offset, data_col])
                    @assert za[end, saved_col] + td === data[data_offset, data_col]
                else
                    data_view = @view data[1:0, :]
                end
            end
            szdv = size(data_view, 1)
            if szdv > 0
                resize!(za, (offset - 1 + szdv, size(za, 2)))
                za[offset:end, :] = data_view[:, :]
                @debug _contiguous_ts(za[:, saved_col], td)
            end
            @debug "Size data_view: " szdv
        # inserting requires overwrite
        else
        # fetch the saved data and combine with new one
        # fetch saved data starting after the last date of the new data
        # which has to be >= saved_first_date because we checked for contig
            saved_offset = Int(max(1, (data_last_ts - saved_first_ts + td) ÷ td))
            saved_data = @view za[saved_offset + 1:end, :]
            szd = size(data, 1)
            ssd = size(saved_data, 1)
            n_cols = size(za, 2)
            @debug ssd + szd, n_cols
            # the new size will include the amount of saved date not overwritten by new data plus new data
            resize!(za, (ssd + szd, n_cols))
            za[szd + 1:end, :] = saved_data[:, :]
            za[begin:szd, :] = data[:, :]
            @debug :data_last, dt(data_last_ts) :saved_first, dt(saved_first_ts)
        end
        @debug "Ensuring contiguity in saved data $(size(za))." _contiguous_ts(za[:, data_col], td)
    else
        offset = 0
        resize!(za, size(data))
        za[:, :] = data[:, :]
    end
    return za
end

function dt(num)
    Dates.unix2datetime(num / 1e3)
end

function dtfloat(d)::AbstractFloat
    Dates.datetime2unix(d) * 1e3
end

function _contiguous_ts(series::AbstractVector{DateTime}, td)
    pv = dtfloat(series[1])
    for i in 2:length(series)
        nv = dtfloat(series[i])
        nv - pv !== td && throw("Time series is not contiguous.")
        pv = nv
    end
    true
end

function _contiguous_ts(series::AbstractVector, td)
    pv = series[1]
    for i in 2:length(series)
        nv = series[i]
        nv - pv !== td && throw("Time series is not contiguous.")
        pv = nv
    end
    true
end

function _check_contiguity(data_first_ts, data_last_ts, saved_first_ts, saved_last_ts, td)
    data_first_ts > saved_last_ts + td &&
        throw("Data stored ends at $(dt(saved_last_ts)) while new data starts at $(dt(data_first_ts)). Data must be contiguous.")
    data_first_ts < saved_first_ts && data_last_ts + td < saved_first_ts &&
        throw("Data stored starts at $(dt(saved_first_ts)) while new data ends at $(dt(data_last_ts)). Data must be contiguous.")
end

function in_repl()
    exc = get_exchange(:kucoin)
    exckeys!(exc, values(Backtest.kucoin_keys())...)
    zi = ZarrInstance()
    exc, zi
end

macro df(v)
    quote
        to_df($(esc(v)))
    end
end

export @df
