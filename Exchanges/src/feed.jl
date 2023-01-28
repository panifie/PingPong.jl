using Python: @pymodule
using Exchanges: get_pairlist
using Python.PythonCall: pyimport, @py, PyDict

function cf_getfeed(; timeout=3)
    # handler = cryptofeed[].FeedHandler()
    # handler.add_feed()
    @pymodule cryptof cryptofeed
    feed = pyimport("src.exchanges.feed")
    rld = pyimport("importlib")
    rld.reload(feed)
    pairs = get_pairlist()
    norm_pairs = []
    for p in keys(pairs)
        push!(norm_pairs, replace(p, "/" => "-"))
    end
    res = feed.run(; timeout, symbols=first(norm_pairs, 10))
    candle = first(res)
    candle
end
