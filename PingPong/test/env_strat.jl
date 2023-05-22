include("env.jl")

STRAT = :ExampleMargin

loadstrat!() = @eval begin
    s = st.strategy(STRAT)
    fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
    dostub!()
    eth = s.universe[m"eth"].instance
end
loadstrat!()
