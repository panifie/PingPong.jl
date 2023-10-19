using Executors: WatchOHLCV
pong!(::Strategy{Sim}, ::WatchOHLCV) = nothing
pong!(::Strategy{Sim}, ::UpdateData) = nothing
pong!(::Function, s::Strategy{Sim}, k, ::UpdateData) = nothing
pong!(::Function, s::Strategy{Sim}, ai, k, ::UpdateData) = nothing
