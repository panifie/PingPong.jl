using SimMode: _simmode_defaults!
using .Instances.Exchanges: lastprice
import .Executors: priceat
using .Misc.Lang: @lget!

@doc "The order task tuple, where `alive` indicates if the task is still alive."
const OrderTaskTuple = NamedTuple{(:task, :alive),Tuple{Task,Ref{Bool}}}
@doc "Keeps track of the consumed volume of an asset (from the daily liquidity)."
const AssetLiquidity = Tuple{Ref{DateTime},Ref{DFT},Ref{DFT}}

@doc """ 
Resets the logs of a given strategy.

$(TYPEDSIGNATURES)

This function resets the logs of a given strategy by clearing the log file associated with the strategy's execution mode.
"""
function reset_logs(s::Strategy)
    mode = execmode(s) |> typeof |> string
    logfile = @lget! attrs(s) :logfile st.logpath(s, name="$(mode)_events")
    write(logfile, "")
end

@doc """ 
Sets the default attributes for a given strategy.

$(TYPEDSIGNATURES)

This function sets the default attributes for a given strategy. It initializes the `paper_liquidity` and `paper_order_tasks` attributes, resets the logs, and applies the default settings for the simulation mode.
"""
function st.default!(s::Strategy{Paper})
    attrs = s.attrs
    attrs[:paper_liquidity] = Dict{AssetInstance,AssetLiquidity}()
    # ensure order tasks do not linger
    tasks = @lget! attrs :paper_order_tasks Dict{Order,OrderTaskTuple}()
    for (_, alive) in values(tasks)
        alive[] = false
    end
    empty!(tasks)
    _simmode_defaults!(s, attrs)
    reset_logs(s)
end

function priceat(::PaperStrategy, ::Type{<:Order}, ai, args...; kwargs...)
    lastprice(ai.asset.raw, ai.exchange)
end
function priceat(s::PaperStrategy, ::T, ai, args...; kwargs...) where {T<:Order}
    priceat(s, T, ai, DateTime(0); kwargs...)
end
