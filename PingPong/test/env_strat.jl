include("env.jl")


loadstrat!(strat=:Example; stub=true, mode=Sim(), kwargs...) = @eval begin
    s = st.strategy($(QuoteNode(strat)); mode=$mode, $(kwargs...))
    fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
    execmode(s) == Sim() && $stub && dostub!()
    eth = s[m"eth"]
end
loadstrat!()

