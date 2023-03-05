module Scrapers
using Data: zi
using TimeTicks

const WORKERS = Ref(10)
const TF = Ref(tf"1m")

function __init__()
    zi[] = zilmdb()
end

include("utils.jl")
include("bybit.jl")
include("binance.jl")

end # module Scrapers
