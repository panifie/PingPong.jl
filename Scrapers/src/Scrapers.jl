module Scrapers
using Data: zi, zilmdb
using TimeTicks

const WORKERS = Ref(10)
const TF = Ref(tf"1m")
const SEM = Base.Semaphore(3)

function __init__()
    zi[] = zilmdb()
end

include("utils.jl")
include("bybit.jl")
include("binance.jl")

end # module Scrapers
