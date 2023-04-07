@doc "Utilities for orderbook based strategies."

using StatsBase: iqr

function mon_obi(exc, pair, runs=60 * 5)
    imbs = Array{Real}(undef, runs)
    price = similar(imbs)
    r = 1
    while r < runs + 1
        imbs[r], price[r] = obimbalance(exc, pair; use_last=true)
        sleep(1)
        r += 1
    end
    imbs, price
end

macro fetchob(args...)
    ob = esc(:ob)
    exc = esc(:exc)
    pair = esc(:pair)
    quote
        if isnothing($ob)
            $ob = $exc.fetchOrderBook($pair)
        end
    end
end

@doc "Aggregates orderbook prices based on volume."
function vwap(data, stepvalue; price_vol=true, bid_ask=true, dosort=true)
    by = price_vol ? :price : :volume
    div_sym = price_vol ? :price_div : :volume_div
    if isnothing(stepvalue)
        stepvalue = iqr(data[:, by])
    end
    # the range label
    data[:, div_sym] = div.(data[:, by], stepvalue)
    # the volume in quote currency
    data[:, :q_volume] = data[:, :price] .* data[:, :volume]
    # group by ranges
    gd = groupby(data, div_sym)
    # apply/combine
    groups = combine(gd, [:q_volume => sum, :volume => sum])
    groups[:, :vwap] = groups[:, :q_volume_sum] ./ groups[:, :volume_sum]
    dosort ? sort(groups, :vwap; rev=bid_ask) : groups
end

@doc "The orderbook imbalance function. [(bids_price - ask_price) / (bids_price + ask_price)]"
function obimbalance(exc, pair; ob=nothing, level=nothing, use_last=false)
    @fetchob
    if isnothing(level) && use_last
        ticker = exc.fetchTicker(pair)
        level = ticker["last"]
    end
    aob = orderbook(exc, pair; ob, stepvalue=level)
    bvs = aob.bids[1, :vwap]
    avs = aob.asks[1, :vwap]
    ((bvs - avs) / (bvs + avs), level)
end

@doc """
- `by` key by which to aggregate values (:price or :volume)
- `stepvalue` size of the bins for aggregation (the range value of :price or :volume). If it is nothing,
it takes the average of the first 10 elements of the array.
"""
function orderbook(exc, pair; ob=nothing, stepvalue::Union{Nothing,Real}=nothing, by=:price)
    @fetchob
    bids = DataFrame(ob["bids"], ["price", "volume"])
    asks = DataFrame(ob["asks"], ["price", "volume"])
    price_vol = by === :price
    (
        ob=ob,
        bids=vwap(bids, stepvalue; price_vol, bid_ask=true),
        asks=vwap(asks, stepvalue; price_vol, bid_ask=false),
    )
end
