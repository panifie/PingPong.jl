
function _check_and_filter(resp; ai, since, kind="")
    pyisinstance(resp, pybuiltins.list) || begin
        @warn "Couldn't fetch $kind trades for $(raw(ai))"
        return nothing
    end
    if isnothing(since)
        resp
    else
        out = pylist()
        for t in resp
            _timestamp(t) >= since && out.append(t)
        end
        out
    end
end

_timestamp(v) = pyconvert(Int, v.get("timestamp", 0)) |> TimeTicks.dtstamp

function live_my_trades(s::LiveStrategy, ai; since=nothing, kwargs...)
    resp = fetch_my_trades(s, ai; since, kwargs...)
    _check_and_filter(resp; ai, since)
end

function live_order_trades(s::LiveStrategy, ai, id; since=nothing, kwargs...)
    resp = fetch_order_trades(s, ai, id; since, kwargs...)
    _check_and_filter(resp; ai, since, kind="order")
end
