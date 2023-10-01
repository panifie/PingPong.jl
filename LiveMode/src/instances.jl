using .Instances: AssetInstance
using .Exchanges: is_pair_active
import .Executors: priceat, ticker!
isactive(ai::AssetInstance) = is_pair_active(raw(ai), exchange(ai))

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
function lastprice(ai::AssetInstance, bs::BySide)
    tk = Exchanges.ticker!(ai)
    eid = exchangeid(ai)
    side_str = _ccxtorderside(bs)
    price = resp_ticker_price(tk, eid, side_str)
    if pyisnone(price)
        get_float(tk, @pyconst("last"))
    else
        pytofloat(price)
    end
end
