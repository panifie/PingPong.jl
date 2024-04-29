#!/usr/bin/env julia

using PingPong
@environment!

strat_name = Symbol(get(ARGS, 1, ""))
strat_mode = let mode = get(ARGS, 2, "Paper") |> titlecase
    if !isnothing(match(r"sim"i, mode))
        Sim()
    elseif !isnothing(match(r"paper"i, mode))
        Paper()
    else
        Live()
    end
end
if strat_name == Symbol()
    error("no strategy name provided")
end
@info "loading strategy $strat_name"
@info "starting in $strat_mode mode"
s = st.strategy(strat_name; sandbox=false)

start!(s, foreground=true)
