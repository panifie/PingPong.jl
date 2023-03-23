module PingPong

# Base.Experimental.@compiler_options optimize = 1 compile = min

using Pkg: Pkg as Pkg
using Python # must be loaded synchronously
@sync for m in :(Misc, Data, ExchangeTypes, Exchanges, Engine).args
    @async eval(:(using $m))
end
include("repl.jl")

function __init__()
    if "JULIA_BACKTEST_REPL" ∈ keys(ENV)
        exc = Symbol(get!(ENV, "JULIA_BACKTEST_EXC", :kucoin))
        Config(exc)
        setexchange!(exc)
    end
    @debug "Initializing python async..."
    Python._async_init()
    # default to using lmdb store for data
    @debug "Initializing LMDB zarr instance..."
    Data.zi[] = Data.zilmdb()
end

export Engine,
    marketsid,
    tickers,
    load_ohlcv,
    user!,
    getexchange!,
    setexchange!,
    config,
    Strategy,
    strategy!,
    config!,
    Config,
    exc

end # module
