module Collections

using Base.Enums: namemap
using DataFrames, DataFramesMeta
using Data: load_pair, zi
using OrderedCollections: OrderedDict
using DataFramesMeta
using DataStructures: SortedDict
using Misc: Iterable, TimeFrame
using ExchangeTypes
using Pairs
using ..Instances

@doc "A collection of assets instances, indexed by asset and exchange identifiers."
struct AssetCollection1
    data::DataFrame
    function AssetCollection1(
        df=DataFrame(; exchange=ExchangeID[], asset=Asset[], instance=AssetInstance[]),
    )
        new(df)
    end
    function AssetCollection1(instances::Iterable{<:AssetInstance})
        DataFrame(
            (; exchange=inst.exchange[].sym, asset=inst.asset, instance=inst) for
            inst in instances;
            copycols=false,
        ) |> AssetCollection1
    end
    function AssetCollection1(
        assets::Union{Iterable{String},Iterable{<:Asset}};
        timeframe="15m",
        exc::Exchange=exc,
    )
        if eltype(assets) == String
            assets = [Asset(name) for name in assets]
        end
        tf = convert(TimeFrame, timeframe)
        getInstance(ast::Asset) = begin
            data = SortedDict(tf => load_pair(zi, exc.name, ast.raw, timeframe))
            AssetInstance(ast, data, exc)
        end
        instances = [getInstance(ast) for ast in assets]
        AssetCollection1(instances)
    end
end
AssetCollection = AssetCollection1

@enum AssetCollectionColumn exchange = 1 asset = 2 instance = 3
const AssetCollectionTypes =
    OrderedDict([exchange => ExchangeID, asset => Asset, instance => AssetInstance])
const AssetCollectionColumns4 = AssetCollectionTypes |> sort! |> keys .|> Symbol
AssetCollectionColumns = AssetCollectionColumns4
const AssetCollectionRow =
    @NamedTuple{exchange::ExchangeID, asset::Asset, instance::AssetInstance}

using Pairs: isbase, isquote
Base.getindex(pf::AssetCollection, i::ExchangeID) = @view pf.data[pf.data.exchange.==i, :]
Base.getindex(pf::AssetCollection, i::Asset) = @view pf.data[pf.data.asset.==i, :]
Base.getindex(pf::AssetCollection, i::String) = @view pf.data[pf.data.asset.==i, :]

# TODO: this should use a macro...
@doc "Dispatch based on either base, quote currency, or exchange."
bqe(df::DataFrame, b::T, q::T, e::T) where {T<:Symbol} = begin
    isbase.(df.asset, b) && isquote.(df.asset, q) && df.exchange .== e
end
bqe(df::DataFrame, ::Nothing, q::T, e::T) where {T<:Symbol} = begin
    isquote(df.asset, q) && df.exchange .== e
end
bqe(df::DataFrame, b::T, ::Nothing, e::T) where {T<:Symbol} = begin
    isbase.(df.asset, b) && df.exchange .== e
end
bqe(df::DataFrame, ::T, q::T, e::Nothing) where {T<:Symbol} = begin
    isbase.(df.asset, b) && isquote.(df.asset, q)
end
bqe(df::DataFrame, ::Nothing, ::Nothing, e::T) where {T<:Symbol} = begin
    df.exchange .== e
end
bqe(df::DataFrame, ::Nothing, q::T, e::Nothing) where {T<:Symbol} = begin
    isquote.(df.asset, q)
end
bqe(df::DataFrame, b::T, ::Nothing, e::Nothing) where {T<:Symbol} = begin
    isbase.(df.asset, b)
end

function Base.getindex(
    pf::AssetCollection;
    b::Union{Symbol,Nothing}=nothing,
    q::Union{Symbol,Nothing}=nothing,
    e::Union{Symbol,Nothing}=nothing,
)
    idx = bqe(pf.data, b, q, e)
    @view pf.data[idx, :]
end

function prettydf(pf::AssetCollection; full=false)
    limit = full ? size(pf.data)[1] : displaysize(stdout)[1] - 1
    limit = min(size(pf.data)[1], limit)
    DataFrame(
        begin
            row = @view pf.data[n, :]
            (; cash=row.instance.cash, name=row.asset.raw, exchange=row.exchange.sym)
        end for n in 1:limit
    )
end

Base.display(pf::AssetCollection) = Base.show(prettydf(pf))

@doc "Returns a Dict{TimeFrame, DataFrame} of all the OHLCV dataframes present in the asset collection."
function flatten(ac::AssetCollection)::SortedDict{TimeFrame,Vector{DataFrame}}
    out = Dict()
    @eachrow ac.data begin
        for (tf, df) in :instance.data
            try
                push!(out[tf], df)
            catch error
                @assert error isa KeyError
                out[tf] = [df]
            end
        end
    end
    out
end

export AssetCollection, flatten

end
