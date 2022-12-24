module JuBot

Base.Experimental.@compiler_options optimize = 1 compile = min

using Requires
using Misc
using Data
using ExchangeTypes
using Exchanges

# include("exchanges/feed.jl")
include("repl.jl")

using Engine

function __init__()
    if "JULIA_BACKTEST_REPL" ∈ keys(ENV)
        exc = Symbol(get!(ENV, "JULIA_BACKTEST_EXC", :kucoin))
        loadconfig!(exc)
        setexchange!(exc)
    end
end

export Engine,
    get_pairs,
    get_pairlist,
    load_pairs,
    user!,
    getexchange!,
    setexchange!,
    Portfolio,
    config,
    Strategy,
    loadstrategy!,
    loadconfig!,
    Config,
    exc

end # module
