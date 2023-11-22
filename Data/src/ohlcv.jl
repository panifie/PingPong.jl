@doc "Columns for OHLCV data: timestamp, open, high, low, close, volume"
const OHLCV_COLUMNS = [:timestamp, :open, :high, :low, :close, :volume]
@doc "Count of [`OHLCV_COLUMNS`](@ref)"
const OHLCV_COLUMNS_COUNT = length(OHLCV_COLUMNS)
@doc "The timestamp column of [`OHLCV_COLUMNS`](@ref)"
const OHLCV_COLUMNS_TS = setdiff(OHLCV_COLUMNS, [:timestamp])
@doc "Only the OHLC columns of [`OHLCV_COLUMNS`](@ref)"
const OHLCV_COLUMNS_NOV = setdiff(OHLCV_COLUMNS, [:timestamp, :volume])

@doc "Similar to a StructArray (and should probably be replaced by it), used for fast conversion."
const OHLCVTuple = Tuple{Vector{DateTime},(Vector{Float64} for _ in 1:5)...}
@doc "Default `OHLCVTuple` value."
function ohlcvtuple()
    (DateTime[], (Float64[] for _ in 2:(length(OHLCV_COLUMNS)))...)
end
Base.append!(a::T, b::T) where {T<:OHLCVTuple} = foreach(splat(append!), zip(a, b))
Base.axes(o::OHLCVTuple) = ((Base.OneTo(size(v, 1)) for v in o)...,)
Base.axes(o::OHLCVTuple, i) = Base.OneTo(size(o[i], 1))
Base.getindex(o::OHLCVTuple, i, j) = o[j][i]
Base.push!(o::OHLCVTuple, tup::Tuple) = begin
    for i in 1:length(tup)
        push!(o[i], tup[i])
    end
end

@doc "Construct an OHLCV dataframe backed by an `OHLCVTuple`."
to_ohlcv(v::OHLCVTuple) = DataFrame([v...], OHLCV_COLUMNS)
propagate_ohlcv!(args...; kwargs...) = error("not implemented")
