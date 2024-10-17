using .Instances: AssetInstance, Position
using .Exchanges: is_pair_active
using .Data.DFUtils: firstdate, lastdate, dateindex, colnames, nrow, setcols!
import .Instances: lastprice
import .Executors: priceat
isactive(ai::AssetInstance) = is_pair_active(raw(ai), exchange(ai))

@doc """ Fetches the price of an asset at a specific date.

$(TYPEDSIGNATURES)

The function `priceat` retrieves the price of a given asset (`ai`) at a specified date (`date`), using a specific strategy (`s`).
The price is fetched from the opening, high, low, or closing price of the asset, as specified by the `step` parameter (default is `:open`).
The symbol for the asset is determined by the `sym` parameter (default is the raw value of the asset instance).
The function uses the `fetch_candles` method to retrieve the price data and returns the price as a float.
If the price data cannot be fetched, the function returns `nothing`.
"""
function priceat(s::Strategy, ai::AssetInstance, date::DateTime; step=:open, sym=raw(ai))
    timeframe = first(exchange(ai).timeframes)
    since = dtstamp(date)
    try
        resp = fetch_candles(s, sym; since, timeframe, limit=1)
        @assert !isempty(resp) "Couldn't fetch candles for $(raw(ai)) at date $(date)"
        candle = resp[0]
        @assert pyconvert(Int, candle[0]) |> dt >= date
        idx = if step == :open
            1
        elseif step == :high
            2
        elseif step == :low
            3
        elseif step == :close
            4
        end
        return pytofloat(candle[idx])
    catch
        return nothing
    end
end

Exchanges.ticker!(ai::AssetInstance) = Exchanges.ticker!(raw(ai), exchange(ai))
@doc """ Fetches the last price of an asset.

$(TYPEDSIGNATURES)

This function retrieves the last price of a given asset (`ai`) for a specific side (`bs`).
It first attempts to get the price from the ticker of the asset.
If the price is not available, it falls back to the last price from the ticker if `last_fallback` is set to `true`.
The function returns the price as a float or `nothing` if the price cannot be fetched.
"""
function lastprice(ai::AssetInstance, bs::BySide; last_fallback=true)
    tk = Exchanges.ticker!(ai)
    eid = exchangeid(ai)
    side_str = _ccxtorderside(bs)
    price = resp_ticker_price(tk, eid, side_str)
    if pyisnone(price)
        if last_fallback
            get_float(tk, @pyconst("last"))
        end
    else
        pytofloat(price)
    end
end

@doc """ Fetches the last price of an asset from the order book.

$(TYPEDSIGNATURES)

This function retrieves the last price of a given asset (`ai`) for a specific side (`bs`) from the order book.
It fetches the order book for the asset and checks if it is a dictionary.
If it is, it asserts that the symbol of the asset matches the symbol in the order book.
Then, it retrieves the list of prices for the specified side from the order book.
If the list exists, it returns the first price in the list as a float.
"""
function lastprice(s, ai::AssetInstance, bs::BySide, ::Val{:ob})
    ob = fetch_l2ob(s, ai)
    if isdict(ob)
        @deassert get_string(ob, "symbol") == raw(ai)
        side_list = get_py(ob, _ccxtobside(bs))
        if islist(side_list)
            return pytofloat(side_list[0][0])
        end
    end
end

function lastprice(s, ai::AssetInstance, bs::BySide)
    @something lastprice(ai, bs, last_fallback=false) lastprice(s, ai, bs, Val(:ob))
end

updates_dict(s) = @lget! s.attrs :updated_at Dict{Tuple{Vararg{Symbol}},DateTime}()
updated_at!(s, k, date=now()) = updates_dict(s)[k] = date
@doc """ Updates the state of a real-time strategy.

$(TYPEDSIGNATURES)

This function applies a given function `f` to update the state of a real-time strategy `s` for a set of columns `cols`.
The function `f` is applied to each asset in the universe of the strategy.
The timeframe `tf` for the update can be specified, with the default being the timeframe of the strategy.
"""
function update!(f::Function, s::RTStrategy, cols::Vararg{Symbol}; tf=s.timeframe)
    updates = updates_dict(s)
    for ai in s.universe
        update!(f, s, ai, cols; updates, tf)
    end
end

@doc """ Attempts to get the size of the data.

$(TYPEDSIGNATURES)

This function tries to get the size of the `data`.
If it can't, it returns a tuple of zeros.
If the data is one-dimensional, it returns a tuple with the size and zero.
If the data is two-dimensional, it returns the size as a tuple.
"""
trysize(data) =
    try
        sz = size(data)
        szlen = length(sz)
        if szlen == 0
            (0, 0)
        elseif szlen == 1
            (sz[1], 0)
        else
            sz
        end
    catch
        (0, 0)
    end

@doc """ Applies a function to update the state of a real-time strategy.

$(TYPEDSIGNATURES)

The function `update!` applies a given function `f` to update the state of a real-time strategy `s` for a set of columns `cols`.
The function `f` is applied to each asset in the universe of the strategy.
The timeframe `tf` for the update can be specified, with the default being the timeframe of the strategy.
"""
function update!(
    f::Function,
    s::RTStrategy,
    ai::AssetInstance,
    cols::Vararg{Symbol};
    updates=updates_dict(s),
    tf=s.timeframe,
)
    ohlcv = @lget! ohlcv_dict(ai) tf empty_ohlcv(s, ai)
    @debug "ohlcv update" _module = LogOHLCV objectid(ohlcv)
    last_update = @lget! updates cols typemin(DateTime)
    if !isempty(ohlcv)
        to_date = lastdate(ohlcv)
        if to_date > last_update
            from_date =
                last_update == typemin(DateTime) ? firstdate(ohlcv) : lastdate(ohlcv) + tf
            new_data = @something f(ohlcv, from_date) ()
            this_size = trysize(new_data)
            this_len = this_size[1]
            this_len == 0 && begin
                @warn "ohlcv update: no new data" to_date last_update
                return nothing
            end
            if this_size[2] != length(cols)
                @warn "ohlcv update: wrong number of columns" expected = length(cols) returned = this_size[2]
                return nothing
            end
            from_idx, exp_size = if last_update == typemin(DateTime)
                1, nrow(ohlcv)
            else
                @deassert !iszero(dateindex(ohlcv, last_update))
                dateindex(ohlcv, from_date, :nonzero), length(from_date:period(tf):to_date)
            end
            @debug "ohlcv update: " _module = LogOHLCV this_len exp_size
            updates[cols] = if this_len < exp_size
                @warn "ohlcv update: size mismatch (missing entries)" this_len exp_size
                @debug "ohlcv update: updated up to" _module = LogOHLCV last_new_date =
                    from_date + period(tf) * this_len
                idx = from_idx:(from_idx + this_len - 1)
                setcols!(ohlcv, new_data, cols, idx)
                ohlcv.timestamp[idx.stop]
            elseif this_len > exp_size
                @warn "ohlcv update: size mismatch (keeping end)" this_len exp_size from_idx from_date lastdate(
                    ohlcv
                )
                idx = from_idx:nrow(ohlcv)
                new_slice = @view new_data[(end - exp_size + 1):end, :]
                setcols!(ohlcv, new_slice, cols, idx)
                to_date
            else
                setcols!(ohlcv, new_data, cols)
                to_date
            end
        end
    end
end

export updated_at!
