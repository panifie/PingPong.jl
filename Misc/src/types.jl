using TimeTicks
using .Sandbox: safereval
const td_tf = TimeTicks.td_tf

abstract type ExecAction end
abstract type ExecMode end
struct Sim <: ExecMode end
struct Paper <: ExecMode end
struct Live <: ExecMode end
execmode(args...; kwargs...) = Sim()

abstract type HedgedMode end
struct Hedged <: HedgedMode end
struct NotHedged <: HedgedMode end
abstract type MarginMode{H<:HedgedMode} end
struct IsolatedMargin{H} <: MarginMode{H} end
struct CrossMargin{H} <: MarginMode{H} end
struct NoMargin <: MarginMode{NotHedged} end

const Isolated = IsolatedMargin{NotHedged}
const IsolatedHedged = IsolatedMargin{Hedged}
const Cross = CrossMargin{NotHedged}
const CrossHedged = CrossMargin{Hedged}
const WithMargin = Union{Cross,Isolated}
marginmode(args...; kwargs...) = NoMargin()

abstract type PositionSide end
struct Long <: PositionSide end
struct Short <: PositionSide end
opposite(::Type{Long}) = Short
opposite(::Long) = Short()
opposite(::Type{Short}) = Long
opposite(::Short) = Long()

const StrOrVec = Union{AbstractString,AbstractVector}
@doc "The floating point number type to use."
const DFT =
    DEFAULT_FLOAT_TYPE = get(ENV, "PINGPONG_FLOAT_TYPE", "Float64") |> Sandbox.safereval
@assert DEFAULT_FLOAT_TYPE isa DataType "$ENV must be edited within julia, before loading pingpong!"
@doc "The margin of error to use [`2eps`]."
const ATOL = @something tryparse(DFT, get(ENV, "PINGPONG_ATOL", "")) 10 * eps()

const MM{T<:Real} = NamedTuple{(:min, :max),Tuple{T,T}}

default_local_dir(args...) = joinpath(ENV["HOME"], ".cache", "PingPong.jl", args...)
function local_dir(args...)
    @something get(ENV, "XDG_CACHE_DIR", nothing) default_local_dir(args...)
end
const DATA_PATH = local_dir("data")

const Iterable = Union{AbstractVector{T},AbstractSet{T},Tuple{Vararg{T}}} where {T}

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

export DFT, ATOL
export Iterable, StrOrVec, ContiguityException
export ExecMode, execmode, ExecAction, Sim, Paper, Live
export MarginMode, marginmode, Isolated, Cross
export NoMargin, WithMargin, Hedged, NotHedged
export PositionSide, Long, Short, opposite
