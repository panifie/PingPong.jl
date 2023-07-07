include("env.jl")


loadstrat!(strat=:Example) = @eval begin
    s = st.strategy($(QuoteNode(strat)))
    fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
    execmode(s) == Sim() && dostub!()
    eth = s.universe[m"eth"].instance
end
loadstrat!()

