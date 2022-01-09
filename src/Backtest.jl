module Backtest

include("misc/utils.jl")
include("exchanges/exchanges.jl")
include("data/data.jl")
include("analysis/analysis.jl")
include("plotting/plotting.jl")

using .Misc
using .Exchanges
using .Data
using .Analysis
using .Plotting

include("repl.jl")

# include("misc/precompile.jl")

end # module
