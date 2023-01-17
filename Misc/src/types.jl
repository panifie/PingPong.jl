using Dates
using DataFrames: AbstractDataFrame, DataFrame, groupby, combine
using TimeTicks: td_tf

const StrOrVec = Union{AbstractString,AbstractVector}

const OHLCV_COLUMNS = [:timestamp, :open, :high, :low, :close, :volume]
const OHLCV_COLUMNS_TS = setdiff(OHLCV_COLUMNS, [:timestamp])
const OHLCV_COLUMNS_NOV = setdiff(OHLCV_COLUMNS, [:timestamp, :volume])

const DATA_PATH =
    get(ENV, "XDG_CACHE_DIR", "$(joinpath(ENV["HOME"], ".cache", "JuBot.jl", "data"))")

const Iterable = Union{AbstractVector{T},AbstractSet{T}} where {T}

struct Candle
    timestamp::DateTime
    open::AbstractFloat
    high::AbstractFloat
    low::AbstractFloat
    close::AbstractFloat
    volume::AbstractFloat
end

@doc "An empty OHLCV dataframe."
function _empty_df()
    DataFrame(
        [DateTime[], [Float64[] for _ in OHLCV_COLUMNS_TS]...],
        OHLCV_COLUMNS;
        copycols=false,
    )
end

@doc "Binds a `mrkts` variable to a Dict{String, DataFrame} \
where the keys are the pairs names and the data is the OHLCV data of the pair."
macro as_dfdict(data, skipempty=true)
    data = esc(data)
    mrkts = esc(:mrkts)
    quote
        if valtype($data) <: PairData
            $mrkts = Dict(p.name => p.data for p in values($data) if size(p.data, 1) > 0)
        end
    end
end

include("exceptions.jl")

export Candle, Iterable, StrOrVec, ContiguityException
