include("env.jl")

s = st.strategy(:ExampleMargin)
fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
dostub!()
eth = s.universe[m"eth"].instance
