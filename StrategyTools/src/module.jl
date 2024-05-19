using PingPong.Engine: Engine as egn
using .egn.Lang
using .egn.TimeTicks
using .egn.Misc
using .egn.Lang.DocStringExtensions
using .egn.Data: empty_ohlcv, nrow, contiguous_ts
using .egn.Data.DataStructures: CircularBuffer, Deque, LittleDict
using .egn.Data.DFUtils: dateindex, firstdate
using .egn.Instruments: raw
using .egn.OrderTypes
using .egn.Instances: Instances as inst, ohlcv, ohlcv_dict, posside, collateral, trades, exchangeid
using .egn.Strategies: strategy, Strategy, AssetInstance, SimStrategy, RTStrategy, marketsid
using .egn.Strategies: freecash, current_total, volumeat, closeat
using .egn.Executors: Context
using .egn.LiveMode: AssetTasks, asset_tasks
using .egn.LiveMode.Watchers.Fetch: update_ohlcv!
using .egn: ispaper, islive
using Statistics: mean

using OnlineTechnicalIndicators: OnlineTechnicalIndicators as oti

include("utils.jl")
include("extrema.jl")
include("orders.jl")
include("trackers.jl")
include("signals.jl")
include("ohlcv.jl")
include("warmup.jl")
include("checks.jl")
include("cross.jl")
