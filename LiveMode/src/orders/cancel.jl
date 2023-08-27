function live_cancel(s, ai; ids=(), side=Both, confirm=false, all=false, since=nothing)
    (func, kwargs) = if all
        (cancel_all_orders, (;))
    else
        (cancel_orders, (; ids, side))
    end
    done = try
        resp = func(s, ai; kwargs...)
        if resp isa PyException
            @warn "Couldn't cancel orders for $(raw(ai)) $resp"
            false
        elseif isnothing(resp)
            true
        elseif pyisinstance(resp, pybuiltins.dict)
            pyisTrue(get_py(resp, "code") == @pyconst("0"))
        else
            false
        end
    catch e
        @warn "Couldn't cancel orders for $(raw(ai)) $e"
        return false
    end
    if done && confirm
        open_orders = fetch_open_orders(
            s, ai; since=isnothing(since) ? nothing : TimeTicks.dtstamp(since)
        )
        if side == Both
            isempty(open_orders) || return false
        else
            side_str = _ccxtorderside(side)
            for o in open_orders
                pyisTrue(get_py(o, "side") == side_str) && return false
            end
        end
    end
    done
end
