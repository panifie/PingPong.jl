using Executors: WatchOHLCV
pong!(s::Strategy{Sim}, ::WatchOHLCV) = nothing
pong!(s::Strategy{Sim}, ::UpdateData) = nothing
