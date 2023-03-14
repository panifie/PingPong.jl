include("env.jl")

s = loadstrategy!(:Example, cfg)
fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
dostub!()
const eth = s.universe[m"eth"].instance
