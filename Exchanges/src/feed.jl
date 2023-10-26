using .Python: pyimport, PyDict, @py, @pymodule
using Exchanges: tickers

function cf_getfeed(; timeout=3)
    # handler = cryptofeed[].FeedHandler()
    # handler.add_feed()
    @pymodule cryptof cryptofeed
    feed = pyimport("src.exchanges.feed")
    rld = pyimport("importlib")
    rld.reload(feed)
    pairs = tickers()
    norm_pairs = []
    for p in keys(pairs)
        push!(norm_pairs, replace(p, "/" => "-"))
    end
    res = feed.run(; timeout, symbols=first(norm_pairs, 10))
    candle = first(res)
    candle
end
