using SimMode
using Executors
using Executors: orders, orderscount
using Executors.OrderTypes
using Executors.TimeTicks
using Executors.Instances
using Executors.Misc
using Executors.Instruments: compactnum as cnum
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

function run!(
    s::Strategy{Paper}; throttle=Second(5), doreset=false, verbose=true, foreground=true
)
    doreset && st.reset!(s)
    verbose && @info "Starting strategy $(nameof(s)) in paper mode!

    throttle: $throttle
    timeframes: $(string(s.timeframe)) (main), $(string(get(s.attrs, :timeframe, nothing))) (optional), $(join(string.(s.config.timeframes), " ")...) (extras)
    cash: $(s.cash) [$(cnum(st.current_total(s, lastprice)))]
    assets: $(let str = join(getproperty.(st.assets(s), :raw), ", "); str[begin:min(length(str), displaysize()[2] - 1)] end)
    margin: $(marginmode(s))
    "
    infofunc = if verbose && foreground
        () -> begin
            long, short, liq = st.trades_count(s, Val(:positions))
            cv = cnum(s.cash.value)
            comm = cnum(s.cash_committed.value)
            inc = orderscount(s, Val(:increase))
            red = orderscount(s, Val(:reduce))
            tot = st.current_total(s, lastprice) |> cnum
            @info "$(now())($(nameof(s))@$(s.exchange)) $comm/$cv[$tot]($(nameof(s.cash))), orders: $inc/$red(+/-) trades: $long/$short/$liq(L/S/Q)"
        end
    else
        Returns(nothing)
    end
    doping() =
        while true
            infofunc()
            ping!(s, now(), nothing)
            sleep(throttle)
        end
    if foreground
        doping()
    else
        @async doping()
    end
end

export run!

include("utils.jl")
include("orders/utils.jl")
include("orders/state.jl")
include("orders/limit.jl")
include("orders/pong.jl")
include("positions/pong.jl")
