@doc """ Log function for a simulation strategy.

$(TYPEDSIGNATURES)

Logs the function `f` with its arguments `args` for the simulation strategy `s`.
"""
log(s::SimStrategy, f, args...) = nothing

@doc """ Log function for a strategy.

$(TYPEDSIGNATURES)

Logs the function `f` with its arguments `args` for the strategy `s`.
"""
log(s::Strategy{<:Union{Paper,Live}}, f, args...) = @info f(args...)

@doc """ Apply function to iterable for a simulation strategy.

$(TYPEDSIGNATURES)

Applies the function `f` to each element of the iterable `iter` for the simulation strategy `s`.
"""
liveloop(f, s::SimStrategy, iter) = foreach(f, iter)

@doc """ Map function asynchronously for a real-time strategy.

$(TYPEDSIGNATURES)

Asynchronously maps the function `f` over the iterable `iter` for the real-time strategy `s`.
"""
liveloop(f, s::RTStrategy, iter) = @sync for i in iter
    @async(f(i)) |> errormonitor
end

@doc """ Apply function to iterable for a strategy.

$(TYPEDSIGNATURES)

Applies the function `f` to each element of the iterable `iter` for the strategy `s`.
"""
liveloop(f, s::Strategy) = liveloop(f, s, s.universe)

@doc """ Sleep function for a real-time strategy.

$(TYPEDSIGNATURES)

Makes the real-time strategy `s` sleep for `n` seconds.
"""
livesleep(s::RTStrategy, n) = sleep(n)

@doc """ Sleep function for a simulation strategy.

$(TYPEDSIGNATURES)

Does nothing for the simulation strategy `s`.
"""
livesleep(s::SimStrategy, _) = nothing

@doc """ Check if last timestamp is within time frame for a simulation strategy.

$(TYPEDSIGNATURES)

Checks if the last timestamp `ts` is within the time frame `tf` for the simulation strategy `s`.
"""
islastts(::SimStrategy, _, ats, tf) = (true, ats)
function islastts(_, ai, ats, tf)
    ts = ohlcv(ai).timestamp
    if lastindex(ts) > 0
        last_date = ts[end]
        (last_date + period(tf) >= ats, last_date)
    else
        (false, DateTime(0))
    end
end

@doc """ Calculate angle of a slope.

$(TYPEDSIGNATURES)

Calculates the angle in degrees of the slope `slp`.
"""
function degrees(slp)
    mod(atan(slp) * (180.0 / π) |> abs, 180.0)
end

@doc """
TimeFrame division

$(TYPEDSIGNATURES)
"""
Base.:(/)(tf::TimeFrame, d; type=Millisecond) = begin
    p = period(tf)
    v = Millisecond(floor(timefloat(p) / d))
    round(v, Millisecond, RoundDown)
end
