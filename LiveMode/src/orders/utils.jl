using .Misc.Lang: @lget!, @deassert, Option
using .Python: @py, pydict
using .Executors: AnyGTCOrder, AnyMarketOrder, AnyIOCOrder, AnyFOKOrder, AnyPostOnlyOrder

const LiveOrderState = NamedTuple{
    (:order, :trade_hashes, :update_hash, :average_price),
    Tuple{Order,Vector{UInt64},Ref{UInt64},Ref{DFT}},
}

const AssetOrdersDict = LittleDict{String,LiveOrderState}

function active_orders(s::LiveStrategy)
    @lget! s.attrs :live_active_orders Dict{AssetInstance,AssetOrdersDict}()
end
function active_orders(s::LiveStrategy, ai)
    ords = active_orders(s)
    @lget! ords ai AssetOrdersDict()
end

function set_active_order!(s::LiveStrategy, ai, o)
    active_orders(s, ai)[o.id] = (;
        order=o,
        trade_hashes=UInt64[],
        update_hash=Ref{UInt64}(0),
        average_price=Ref(o.price),
    )
end

function show_active_orders(s::LiveStrategy, ai)
    open_orders = fetch_open_orders(s, ai)
    open_ids = Set(resp_order_id.(open_orders))
    active = active_orders(s, ai)
    for id in keys(active)
        println(stdout, string(id, " open: ", id ∈ open_ids))
    end
    flush(stdout)
end

macro _isfilled()
    expr = quote
        # fallback to local
        if isfilled(o)
            decommit!(s, o, ai)
            delete!(s, ai, o)
        end
    end
    esc(expr)
end
