using .Misc.Lang: @lget!, @deassert, Option, @logerror
using .Python: @py

function live_cancel(s, ai; ids=(), side=Both, confirm=false, all=false)
    func = st.attr(s, all ? :live_cancel_all_func : :live_cancel_func)
    done = try
        resp = func(ai; ids, side)
        if resp isa PyException
            @warn "Couldn't cancel orders for $(raw(ai)) $resp"
            false
        else
            pyisTrue(resp.get("code") == @pystr("0"))
        end
    catch e
        @warn "Couldn't cancel orders for $(raw(ai)) $e"
        return false
    end
    if done && confirm
        all_orders = fetch_orders(s, ai; side, ids)
    else
        done
    end
end
