module Backtest

if isdefined(Base, :Experimental) &&
   isdefined(Base.Experimental, Symbol("@compiler_options"))
    @eval Base.Experimental.@compiler_options optimize = 1 compile = min
end

using Requires
using Misc

using Data
using Exchanges

# include("exchanges/feed.jl")

using Analysis
using Plotting

include("repl.jl")

using ExchangeTypes

using Engine

export Engine,
    get_pairs,
    get_pairlist,
    load_pairs,
    user!,
    getexchange!,
    setexchange!,
    portfolio,
    config,
    Strategy,
    exc

end # module
