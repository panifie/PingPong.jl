using SimMode
using Executors
using Executors.OrderTypes
using Executors.TimeTicks
using Executors.Instances
using Executors.Misc
using .Misc.TimeToLive: safettl
using .Misc.Lang: @lget!, @deassert
using Executors.Strategies: MarginStrategy, Strategy, Strategies as st, ping!
using Executors.Strategies
using .Instances: MarginInstance
using .Instances.Exchanges: CcxtTrade
using .Instances.Data.DataStructures: CircularBuffer
using SimMode: AnyMarketOrder, AnyLimitOrder
import Executors: pong!, run!
using Fetch: pytofloat

const TradesCache = Dict{AssetInstance,CircularBuffer{CcxtTrade}}()

function run!(s::Strategy{Paper}; throttle=Second(5), doreset=true, verbose=true)
    doreset && st.reset!(s)
    verbose && @info "Starting strategy $(nameof(s)) in paper mode! (throttle: $throttle)"
    infofunc = if verbose
        () -> @info "Pinging strategy ($(now()))"
    else
        Returns(nothing)
    end
    while true
        infofunc()
        ping!(s, now(), nothing)
        sleep(throttle)
    end
end

export run!

include("utils.jl")
include("orders/utils.jl")
include("orders/state.jl")
include("orders/limit.jl")
include("orders/pong.jl")
include("positions/pong.jl")
