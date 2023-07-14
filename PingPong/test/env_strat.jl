include("env.jl")


loadstrat!(strat=:Example; mode=Sim(), kwargs...) = @eval begin
    s = st.strategy($(QuoteNode(strat)); mode=$mode, $(kwargs...))
    fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
    execmode(s) == Sim() && dostub!()
    eth = s.universe[m"eth"].instance
end
loadstrat!()

