using TimeTicks
const td_tf = TimeTicks.td_tf

const StrOrVec = Union{AbstractString,AbstractVector}

const DATA_PATH = get(
    ENV, "XDG_CACHE_DIR", "$(joinpath(ENV["HOME"], ".cache", "PingPong.jl", "data"))"
)

const Iterable = Union{AbstractVector{T},AbstractSet{T}, Tuple{Vararg{T}}} where {T}

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

function drop(nt::NamedTuple, keys::NTuple{N,Symbol}) where {N}
    Base.structdiff(nt, NamedTuple{keys})
end

include("exceptions.jl")

export Iterable, StrOrVec, ContiguityException
