module User

using Requires
using Misc
using Data
using Exchanges

# include("exchanges/feed.jl")

using Analysis
using Plotting

include("repl.jl")

using Exchanges: Exchange
export get_pairlist, load_pairs, Exchange, explore!, user!

end # module
