module ForwardingStrat
using PingPong

const DESCRIPTION = "Template"
const EXC = :binance
const TF = tf"1m"

@strategyenv!
using .Strategies.Forward
include("Example.jl")

function ping!(s::SC, ts::DateTime, _)
    ats = available(s.timeframe, ts)
    foreach(s.universe) do ai
        nothing
    end
end

@forwardstrategy Example

end
