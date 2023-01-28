module JuBot

Base.Experimental.@compiler_options optimize = 1 compile = min

using Python
@sync for m in :(Misc, Data, ExchangeTypes, Exchanges, Engine, Watchers).args
    @async eval(:(using $m))
end
include("repl.jl")
include("orders.jl")

function __init__()
    if "JULIA_BACKTEST_REPL" ∈ keys(ENV)
        exc = Symbol(get!(ENV, "JULIA_BACKTEST_EXC", :kucoin))
        loadconfig!(exc)
        setexchange!(exc)
    end
    Python._async_init()
end

export Engine,
    get_pairs,
    get_pairlist,
    load_ohlcv,
    user!,
    getexchange!,
    setexchange!,
    config,
    Strategy,
    loadstrategy!,
    loadconfig!,
    Config,
    exc

end # module
