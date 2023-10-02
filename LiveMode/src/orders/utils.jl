using .Misc.Lang: @lget!, @deassert, Option
using .Python: @py, pydict
using .Executors:
    AnyGTCOrder, AnyMarketOrder, AnyLimitOrder, AnyIOCOrder, AnyFOKOrder, AnyPostOnlyOrder

const LiveOrderState = NamedTuple{
    (:order, :lock, :trade_hashes, :update_hash, :average_price),
    Tuple{Order,ReentrantLock,Vector{UInt64},Ref{UInt64},Ref{DFT}},
}

const AssetOrdersDict = LittleDict{String,LiveOrderState}

function active_orders(s::LiveStrategy)
    @lget! attrs(s) :live_active_orders Dict{AssetInstance,AssetOrdersDict}()
end
function active_orders(s::LiveStrategy, ai)
    ords = active_orders(s)
    @lget! ords ai AssetOrdersDict()
end

avgprice(o::Order) =
    let order_trades = trades(o)
        isempty(order_trades) && return o.price
        val = zero(DFT)
        amt = zero(DFT)
        for t in order_trades
            val += t.value
            amt += t.amount
        end
        return val / amt
    end

function set_active_order!(s::LiveStrategy, ai, o; ap=avgprice(o))
    state = @lget! active_orders(s, ai) o.id (;
        order=o,
        lock=ReentrantLock(),
        trade_hashes=UInt64[],
        update_hash=Ref{UInt64}(0),
        average_price=Ref(iszero(ap) ? avgprice(o) : ap),
    )
    watch_trades!(s, ai) # ensure trade watcher is running
    watch_orders!(s, ai) # ensure orders watcher is running
    state
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

function waitfor_closed(
    s::LiveStrategy, ai, waitfor=Second(5); t::Type{<:OrderSide}=Both, synced=true
)
    try
        active = active_orders(s, ai)
        slept = 0
        timeout = Millisecond(waitfor).value
        success = true
        @debug "wait ord close: waiting" ai = raw(ai) side = t
        while true
            isactive(s, ai; active, side=t) || begin
                @debug "wait ord close: done" ai = raw(ai)
                break
            end
            slept < timeout || begin
                success = false
                @debug "wait ord close: timedout" ai = raw(ai) side = t waitfor f = @caller
                if synced
                    @warn "wait ord close: syncing"
                    live_sync_active_orders!(s, ai; side=t, strict=false, exec=true)
                    success = if isactive(s, ai; side=t)
                        @error "wait ord close: orders still active" side = t n = orderscount(
                            s, ai, t
                        ) length(active_orders(s, ai))
                        false
                    else
                        true
                    end
                end
                break
            end
            sleep(0.1)
            slept += 100
        end
        if success
            if orderscount(s, ai, t) > 0
                @debug "wait ord close: syncing(2nd) f" orderscount(s, ai, t)
                live_sync_active_orders!(s, ai; side=t, strict=false, exec=true)
                orderscount(s, ai, t) > 0
            else
                true
            end
        else
            false
        end
    catch
        @debug_backtrace
        false
    end
end

function isactive(s::LiveStrategy, ai; active=active_orders(s, ai), side=Both)
    for state in values(active)
        orderside(state.order) == side && return true
    end
    return false
end

function isactive(
    s::LiveStrategy, ai, o::AnyLimitOrder; pt=pricetime(o), active=active_orders(s, ai)
)
    haskey(s, ai, pt, o) && haskey(active, o.id)
end

function isactive(s::LiveStrategy, ai, o; active=active_orders(s, ai), kwargs...)
    haskey(active, o.id)
end
