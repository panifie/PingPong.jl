using Dates: AbstractDateTime
const DateType = Union{AbstractString,AbstractDateTime,AbstractFloat,Integer}
const TimeFrameOrStr = Union{TimeFrame,AbstractString}
export DateType

@doc "Mapping of timeframes to default window sizes."
const tf_win = IdDict(
    "1m" => 20,  #  20m
    "5m" => 12,  #  1h
    "15m" => 16,  #  4h
    "30m" => 16,  #  8h
    "1h" => 24,  #  24h
    "2h" => 24,  #  48h
    "4h" => 42,  #  1w
    "8h" => 42,  #  2w
    "1d" => 26,   #  4w
)

# NOTE: This can't be an IdDict if we want indexing with floats
@doc "Reverse mapping of timedeltas (milliseconds) to timeframes."
const td_tf = IdDict(
    60000 => "1m",
    300000 => "5m",
    900000 => "15m",
    1800000 => "30m",
    3600000 => "1h",
    7200000 => "2h",
    14400000 => "4h",
    28800000 => "8h",
    43200000 => "12h",
    86400000 => "1d",
)

const tf_parse_map = Dict{String,TimeFrame}()
const tf_name_map = Dict{Period,String}() # FIXME: this should be benchmarked to check if caching is worth it
const tf_conv_map = Dict{Period,TimeFrame}()
const tf_map = Dict{String,Tuple{TimeFrame,Float64}}() # FIXME: this should be benchmarked to check if caching is worth it
# DateRange
const OptDate = Union{Nothing,DateTime}
const DateTuple = NamedTuple{(:start, :stop),NTuple{2,DateTime}}
