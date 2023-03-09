module Sim

include("mootils.jl")
using .Mootils: Mootils as mt
using Data: Candle

include("types.jl")
include("rois.jl")
include("stoploss.jl")
include("profits.jl")
include("spread.jl")
include("liq.jl")
include("skew.jl")
include("buy.jl")

end
