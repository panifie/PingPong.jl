module Backtest

include("misc/utils.jl"); using .Misc
include("exchanges/exchanges.jl"); using .Exchanges
include("data/data.jl"); using .Data

# load fetch functions, that depend on `.Data`...circ deps...
Exchanges.fetch!()

include("analysis/analysis.jl")
include("plotting/plotting.jl")

using .Analysis
using .Plotting

include("repl.jl")

include("misc/precompile.jl")

end # module
