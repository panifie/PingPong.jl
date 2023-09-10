include("env.jl")

loadstrat!(strat=:Example; stub=true, mode=Sim(), kwargs...) = @eval begin
    GC.gc()
    s = st.strategy($(QuoteNode(strat)); mode=$mode, $(kwargs)...)
    st.issim(s) && fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
    execmode(s) == Sim() && $stub && dostub!()
    st.ordersdefault!(s)
    lm.exc_live_funcs!(s)
    eth = s[m"eth"]
end

