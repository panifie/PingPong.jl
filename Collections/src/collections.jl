using Instances
using Instances: NoMarginInstance, MarginInstance

using Data.DataFrames
using Data.DataFramesMeta
using Data: load, zi, empty_ohlcv
using Data.DFUtils
using Data.DataStructures: SortedDict

using ExchangeTypes
using Instruments: fiatnames, AbstractAsset, Asset, Cash, compactnum as cnum
using Instruments.Derivatives
using TimeTicks
using Misc: Iterable, swapkeys, MarginMode
using Lang: @lget!, MatchString
using Base.Enums: namemap
using OrderedCollections: OrderedDict

# TYPENUM
@doc "A collection of assets instances, indexed by asset and exchange identifiers."
struct AssetCollection
    data::DataFrame
    function AssetCollection(
        df=DataFrame(;
            exchange=ExchangeID[], asset=AbstractAsset[], instance=AssetInstance[]
        ),
    )
        new(df)
    end
    function AssetCollection(instances::Iterable{<:AssetInstance})
        AssetCollection(
            DataFrame(
                (; exchange=inst.exchange.id, asset=inst.asset, instance=inst) for
                inst in instances;
                copycols=false,
            ),
        )
    end
    function AssetCollection(
        assets::Union{Iterable{String},Iterable{<:AbstractAsset}};
        timeframe="1m",
        exc::Exchange,
        margin::MarginMode,
        min_amount=1e-8,
        load_data=true,
    )
        if eltype(assets) == String
            assets = [parse(AbstractAsset, name) for name in assets]
        end

        tf = convert(TimeFrame, timeframe)
        load_func = if load_data
            (aa) -> load(zi, exc.name, aa.raw, timeframe)
        else
            (_) -> empty_ohlcv()
        end
        function getInstance(aa::AbstractAsset)
            data = SortedDict(tf => load_func(aa))
            AssetInstance(aa; data, exc, margin, min_amount)
        end
        instances = [getInstance(ast) for ast in assets]
        AssetCollection(instances)
    end
end

@enum AssetCollectionColumn exchange = 1 asset = 2 instance = 3
const AssetCollectionTypes = OrderedDict([
    exchange => ExchangeID, asset => AbstractAsset, instance => AssetInstance
])
const AssetCollectionColumns4 = Symbol.(keys(sort!(AssetCollectionTypes)))
AssetCollectionColumns = AssetCollectionColumns4
# HACK: const/types definitions inside macros can't be revised
if !isdefined(@__MODULE__, :AssetCollectionRow)
    const AssetCollectionRow = @NamedTuple{
        exchange::ExchangeID, asset::AbstractAsset, instance::AssetInstance
    }
end

using Instruments: isbase, isquote
function Base.getindex(ac::AssetCollection, i::ExchangeID, col=Colon())
    @view ac.data[ac.data.exchange .== i, col]
end
function Base.getindex(ac::AssetCollection, i::AbstractAsset, col=Colon())
    @view ac.data[ac.data.asset .== i, col]
end
function Base.getindex(ac::AssetCollection, i::AbstractString, col=Colon())
    @view ac.data[ac.data.asset .== i, col]
end
function Base.getindex(ac::AssetCollection, i::MatchString, col=Colon())
    v = @view ac.data[startswith.(getproperty.(ac.data.asset, :raw), uppercase(i.s)), :]
    isempty(v) && return v
    @view v[begin, col]
end
Base.getindex(ac::AssetCollection, i, i2, i3) = ac[i, i2][i3]

# TODO: this should use a macro...
@doc "Dispatch based on either base, quote currency, or exchange."
function bqe(df::DataFrame, b::T, q::T, e::T) where {T<:Symbol}
    isbase.(df.asset, b) && isquote.(df.asset, q) && df.exchange .== e
end
function bqe(df::DataFrame, ::Nothing, q::T, e::T) where {T<:Symbol}
    isquote(df.asset, q) && df.exchange .== e
end
function bqe(df::DataFrame, b::T, ::Nothing, e::T) where {T<:Symbol}
    isbase.(df.asset, b) && df.exchange .== e
end
function bqe(df::DataFrame, ::T, q::T, e::Nothing) where {T<:Symbol}
    isbase.(df.asset, b) && isquote.(df.asset, q)
end
bqe(df::DataFrame, ::Nothing, ::Nothing, e::T) where {T<:Symbol} = begin
    df.exchange .== e
end
function bqe(df::DataFrame, ::Nothing, q::T, e::Nothing) where {T<:Symbol}
    isquote.(df.asset, q)
end
bqe(df::DataFrame, b::T, ::Nothing, e::Nothing) where {T<:Symbol} = begin
    isbase.(df.asset, b)
end

function Base.getindex(
    ac::AssetCollection;
    b::Union{Symbol,Nothing}=nothing,
    q::Union{Symbol,Nothing}=nothing,
    e::Union{Symbol,Nothing}=nothing,
)
    idx = bqe(ac.data, b, q, e)
    @view ac.data[idx, :]
end

_cashstr(ai::NoMarginInstance) = (; cash=cash(ai).value)
function _cashstr(ai::MarginInstance)
    (; cash_long=cash(ai, Long()).value, cash_short=cash(ai, Short()).value)
end
function prettydf(ac::AssetCollection; full=false)
    limit = full ? size(ac.data)[1] : displaysize(stdout)[1] - 1
    limit = min(size(ac.data)[1], limit)
    DataFrame(
        begin
            row = @view ac.data[n, :]
            (; _cashstr(row.instance)..., name=row.asset, exchange=row.exchange.id)
        end for n in 1:limit
    )
end

Base.show(io::IO, ac::AssetCollection) = write(io, string(prettydf(ac)))

@doc "Returns a Dict{TimeFrame, DataFrame} of all the OHLCV dataframes present in the asset collection."
function flatten(ac::AssetCollection)::SortedDict{TimeFrame,Vector{DataFrame}}
    out = Dict()
    @eachrow ac.data for (tf, df) in :instance.data
        push!(@lget!(out, tf, DataFrame[]), df)
    end
    out
end

Base.first(ac::AssetCollection, a::AbstractAsset)::DataFrame =
    first(first(ac[a].instance).data)[2]

@doc "Makes a daterange that spans the common min and max dates of the collection."
function TimeTicks.DateRange(ac::AssetCollection, tf=nothing)
    m = typemin(DateTime)
    M = typemax(DateTime)
    for ai in ac.data.instance
        d_min = firstdate(first(values(ai.data)))
        d_min > m && (m = d_min)
        d_max = lastdate(last(ai.data).second)
        d_max < M && (M = d_max)
    end
    tf = @something tf first(ac.data[begin, :instance].data).first
    DateRange(m, M, tf)
end

Base.iterate(ac::AssetCollection) = iterate(ac.data.instance)
Base.iterate(ac::AssetCollection, s) = iterate(ac.data.instance, s)
Base.first(ac::AssetCollection) = first(ac.data.instance)
Base.last(ac::AssetCollection) = last(ac.data.instance)
Base.length(ac::AssetCollection) = nrow(ac.data)
Base.size(ac::AssetCollection) = size(ac.data)
Base.similar(ac::AssetCollection) = begin
    AssetCollection(similar.(ac.data.instance))
end

@doc "Checks that all assets in the universe match the cash."
iscashable(c::Cash, ac::AssetCollection) = begin
    for ai in ac
        if ai.asset.qc != nameof(c)
            return false
        end
    end
    return true
end

export AssetCollection, flatten, iscashable
