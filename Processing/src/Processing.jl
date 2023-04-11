module Processing
using Lang: @preset, @precomp

include("normalize.jl")
include("resample.jl")
include("ohlcv.jl")
include("tradesohlcv.jl")
include("align.jl")
include("precompile.jl")

end # module Processing
