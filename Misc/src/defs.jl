ping!(args...; kwargs...) = error("Not implemented")
pong!(args...; kwargs...) = error("Not implemented")

start!(args...; kwargs...) = error("not implemented")
stop!(args...; kwargs...) = error("not implemented")
isrunning(args...; kwargs...) = error("not implemented")
load!(args...; kwargs...) = error("not implemented")

export start!, stop!, isrunning
export load!
export ping!, pong!
