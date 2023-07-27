using SimMode: _simmode_defaults!
using .Instances.Exchanges: lastprice
import Executors: priceat
using .Misc.Lang: @lget!

const OrderTaskTuple = NamedTuple{(:task, :alive),Tuple{Task,Ref{Bool}}}

function reset_logs(s::Strategy)
    mode = execmode(s) |> typeof |> string
    logfile = @lget! s.attrs :logfile st.logpath(s, name="$(mode)_events")
    write(logfile, "")
end

function OrderTypes.ordersdefault!(s::Strategy{Paper})
    let attrs = s.attrs
        attrs[:paper_liquidity] = Dict{
            AssetInstance,Tuple{Ref{DateTime},Ref{DFT},Ref{DFT}}
        }()
        # ensure order tasks do not linger
        tasks = @lget! attrs :paper_order_tasks Dict{Order,OrderTaskTuple}()
        for (_, alive) in values(tasks)
            alive[] = false
        end
        empty!(tasks)
        _simmode_defaults!(s, attrs)
        reset_logs(s)
    end
end

function priceat(::PaperStrategy, ::Type{<:Order}, ai, args...; kwargs...)
    lastprice(ai.asset.raw, ai.exchange)
end
function priceat(s::PaperStrategy, ::T, ai, args...; kwargs...) where {T<:Order}
    priceat(s, T, ai, DateTime(0); kwargs...)
end
