using Executors: WatchOHLCV
pong!(::Strategy{Sim}, ::WatchOHLCV) = nothing
pong!(::Strategy{Sim}, ::UpdateData) = nothing
pong!(::Function, s::Strategy{Sim}, ::UpdateData; cols::Tuple{Vararg{Symbol}}) = nothing
pong!(::Function, s::Strategy{Sim}, ai, ::UpdateData; cols::Tuple{Vararg{Symbol}}) = nothing
