module Backtest

if isdefined(Base, :Experimental) && isdefined(Base.Experimental, Symbol("@compiler_options"))
    @eval Base.Experimental.@compiler_options optimize=0 compile=min
end

using Requires
using Misc

using Data
using Exchanges

# include("exchanges/feed.jl")

using Analysis
using Plotting

include("repl.jl")

using Exchanges: Exchange

import Engine

export Engine, get_pairlist, load_pairs, Exchange, user!, getexchange!, setexchange!, portfolio

end # module
