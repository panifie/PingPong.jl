import Pkg;
let dse =  "~/.julia/environments/$(VERSION)/"
    if dse ∉ LOAD_PATH
        push!(LOAD_PATH, dse)
    end
end
using Documenter, DocStringExtensions

# Modules
using Backtest
using Pbar
project_path = Pkg.project().path |> dirname
function use(name, args...)
    path = joinpath(project_path, args...)
    path ∉ LOAD_PATH && push!(LOAD_PATH, path)
    eval(Base.Meta.parse("using $(name)"))
end
use(:Prices, "Data", "src")
use(:Fetch, "Exchanges", "Fetch")
use(:Short, "Analysis", "Mark", "Short")
use(:Long, "Analysis", "Mark", "Long")
use(:MVP, "Analysis", "Mark", "MVP")

# using User.Misc: fiatnames, tf_win, td_tf, ohlcv_limits, futures_exchange
makedocs(sitename="Backtest.jl")
