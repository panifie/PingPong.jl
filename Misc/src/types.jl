using TimeTicks
using .Sandbox: safereval
import Base: ==
const td_tf = TimeTicks.td_tf

@doc "An `ExecAction` is any holy trait singleton used to dispatch `ping!` and `pong!` functions."
abstract type ExecAction end
@doc "ExecMode is one of `Sim`, `Paper`, `Live`."
abstract type ExecMode end
@doc "Simulated execution."
struct Sim <: ExecMode end
@doc "Paper execution."
struct Paper <: ExecMode end
@doc "Live execution."
struct Live <: ExecMode end
@doc "Returns the execution mode of the arguments."
execmode(args...; kwargs...) = Sim()

@doc "`HedgedMode` is one of `Hedged`, `NotHedged`."
abstract type HedgedMode end
@doc "`Hedged` implies both short and long positions can be held."
struct Hedged <: HedgedMode end
@doc "`NotHedged` implies only one position side can be held."
struct NotHedged <: HedgedMode end
@doc "Margin mode is one of `Isolated`, `Cross`, `NoMargin`."
abstract type MarginMode{H<:HedgedMode} end
@doc "Isolated margin mode handles margin for each asset separately."
struct IsolatedMargin{H} <: MarginMode{H} end
@doc "Cross margin mode handles margin across all assets (NOT IMPLEMENTED)."
struct CrossMargin{H} <: MarginMode{H} end
@doc "No margin mode, margin handling is disabled (usually in simple spot markets)."
struct NoMargin <: MarginMode{NotHedged} end

@doc "NotHedged IsolatedMargin mode."
const Isolated = IsolatedMargin{NotHedged}
@doc "Hedged IsolatedMargin mode."
const IsolatedHedged = IsolatedMargin{Hedged}
@doc "NotHedged CrossMargin mode."
const Cross = CrossMargin{NotHedged}
@doc "Hedged CrossMargin mode."
const CrossHedged = CrossMargin{Hedged}
@doc "Any margin mode."
const WithMargin = Union{Cross,Isolated}
@doc "Returns the margin mode of the arguments."
marginmode(args...; kwargs...) = NoMargin()
marginmode(v::String) =
    if v == "isolated"
        IsolatedMargin
    elseif v == "cross"
        CrossMargin
    else
        error("unsupported margin mode $v")
    end

@doc "Position side is one of `Long`, `Short`."
abstract type PositionSide end
@doc "Long position side."
struct Long <: PositionSide end
@doc "Short position side."
struct Short <: PositionSide end
@doc "The opposite position side (Long -> Short, Short -> Long)"
opposite(::Type{Long}) = Short
opposite(::Long) = Short()
opposite(::Type{Short}) = Long
opposite(::Short) = Long()
const ObjectOrType{T} = Union{T,Type{T}}
==(::ObjectOrType{Long}, ::ObjectOrType{Long}) = true
==(::ObjectOrType{Short}, ::ObjectOrType{Short}) = true

const StrOrVec = Union{AbstractString,AbstractVector}
@doc "The floating point number type to use."
const DFT =
    DEFAULT_FLOAT_TYPE = get(ENV, "PINGPONG_FLOAT_TYPE", "Float64") |> Sandbox.safereval
@doc "Static `zero(DFT)`"
const ZERO = zero(DFT)
@assert DEFAULT_FLOAT_TYPE isa DataType "$ENV must be edited within julia, before loading pingpong!"
@doc "The margin of error to use [`2eps`]."
const ATOL = @something tryparse(DFT, get(ENV, "PINGPONG_ATOL", "")) 10 * eps()

@doc "Min, max named tuple"
const MM{T<:Real} = NamedTuple{(:min, :max),Tuple{T,T}}

# TODO: This should use `Scratch.jl` instead
@doc "Returns the default local directory."
default_local_dir(args...) = joinpath(ENV["HOME"], ".cache", "PingPong", args...)
function local_dir(args...)
    xdg = get(ENV, "XDG_CACHE_DIR", nothing)
    if isnothing(xdg)
        default_local_dir(args...)
    else
        joinpath(xdg, "PingPong")
    end
end
const DATA_PATH = local_dir("data")

@doc "An union of iterable types."
const Iterable = Union{AbstractVector{T},AbstractSet{T},Tuple{Vararg{T}}} where {T}

@doc "Binds a `mrkts` variable to a Dict{String, DataFrame} \
where the keys are the pairs names and the data is the OHLCV data of the pair.

$(TYPEDSIGNATURES)
"
macro as_dfdict(data, skipempty=true)
    data = esc(data)
    mrkts = esc(:mrkts)
    quote
        if valtype($data) <: PairData
            $mrkts = Dict(p.name => p.data for p in values($data) if size(p.data, 1) > 0)
        end
    end
end

@doc "Returns a NamedTuple without the given keys."
function drop(nt::NamedTuple, keys::NTuple{N,Symbol}) where {N}
    Base.structdiff(nt, NamedTuple{keys})
end

include("exceptions.jl")

export DFT, ATOL, ZERO
export Iterable, StrOrVec, ContiguityException
export ExecMode, execmode, ExecAction, Sim, Paper, Live
export MarginMode, marginmode, Isolated, Cross
export NoMargin, WithMargin, Hedged, NotHedged
export PositionSide, Long, Short, opposite
