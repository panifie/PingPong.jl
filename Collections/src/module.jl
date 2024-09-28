using Instances
using Instances.Exchanges.ExchangeTypes
using Instances.Exchanges: getexchange!
using Instances: OrderTypes, Data, Instruments
using Instances: NoMarginInstance, MarginInstance

using .Data.DataFrames
using .Data.DataFramesMeta
using .Data: load, zi, empty_ohlcv
using .Data.DFUtils
using .Data.DataStructures: SortedDict

using .Instruments: fiatnames, AbstractAsset, Asset, AbstractCash, compactnum as cnum
using .Instruments.Derivatives
using .Instruments: Misc
using .Misc: TimeTicks, Lang
using .TimeTicks
using .Misc: Iterable, swapkeys, MarginMode
using .Lang: @lget!, MatchString, Option
using Base.Enums: namemap
using .Misc: OrderedDict, OrderedCollections
using .Misc.DocStringExtensions
import .Misc: reset!

@doc """A type representing a collection of asset instances.

$(FIELDS)

This type is used to store and manage a collection of asset instances. Each instance is linked to an asset and an exchange identifier.
Elements from `AssetCollection` can be accessed using `getindex` and `setindex!` which accepts different types including `ExchangeID`, `AbstractAsset`, `AbstractString`, `MatchString`, or a combination of base, quote currency, and exchange.
Iterating over the collection only iterates over the instances within.

"""
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
        function get_instance(aa::AbstractAsset)
            data = SortedDict(tf => load_func(aa))
            AssetInstance(aa; data, exc, margin, min_amount)
        end
        instances_ord = Dict(raw(k) => n for (n, k) in enumerate(assets))
        instances = AssetInstance[]
        @sync for ast in assets
            @async push!(instances, get_instance(ast))
        end
        sort!(instances; by=(ai) -> instances_ord[raw(ai)])
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

using .Instruments: isbase, isquote
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
    if col == Colon()
        v[begin, :instance]
    else
        @view v[begin, col]
    end
end
Base.getindex(ac::AssetCollection, i, i2, i3) = ac[i, i2][i3]
Base.get(ac::AssetCollection, i, val) = get(ac.data.instance, i, val)

# TODO: this should use a macro...
@doc "Dispatch based on either base, quote currency, or exchange."
function bqe(df::DataFrame, b::T, q::T, e::T) where {T<:Symbol}
    isbase.(df.asset, b) .&& isquote.(df.asset, q) .&& df.exchange .== e
end
function bqe(df::DataFrame, ::Nothing, q::T, e::T) where {T<:Symbol}
    isquote(df.asset, q) && df.exchange .== e
end
function bqe(df::DataFrame, b::T, ::Nothing, e::T) where {T<:Symbol}
    isbase.(df.asset, b) && df.exchange .== e
end
function bqe(df::DataFrame, b::T, q::T, e::Nothing) where {T<:Symbol}
    isbase.(df.asset, b) .&& isquote.(df.asset, q)
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

@doc """Pretty prints the AssetCollection DataFrame.

$(TYPEDSIGNATURES)

The `prettydf` function takes the following parameters:

- `ac`: an AssetCollection object which encapsulates a collection of assets.
- `full` (optional, default is false): a boolean that indicates whether to print the full DataFrame. If true, the function prints the full DataFrame. If false, it prints a truncated version.
"""
function prettydf(ac::AssetCollection; full=false)
    limit = full ? size(ac.data)[1] : displaysize(stdout)[1] - 1
    limit = min(size(ac.data)[1], limit)
    get_row(n) = begin
        row = @view ac.data[n, :]
        (; _cashstr(row.instance)..., name=row.asset, exchange=row.exchange.id)
    end
    half = limit ÷ 2
    df = DataFrame(get_row(n) for n in 1:half)
    for n in (nrow(ac.data) - half + 1):nrow(ac.data)
        push!(df, get_row(n))
    end
    df
end

Base.show(io::IO, ac::AssetCollection) = write(io, string(prettydf(ac)))

@doc """Returns a dictionary of all the OHLCV dataframes present in the asset collection.

$(TYPEDSIGNATURES)

The `flatten` function takes the following parameter:

- `ac`: an AssetCollection object which encapsulates a collection of assets.

The function returns a SortedDict where the keys are TimeFrame objects and the values are vectors of DataFrames that represent OHLCV (Open, High, Low, Close, Volume) data. The dictionary is sorted by the TimeFrame keys.

"""
function flatten(ac::AssetCollection)::SortedDict{TimeFrame,Vector{DataFrame}}
    out = SortedDict{TimeFrame,Vector{DataFrame}}()
    @eachrow ac.data for (tf, df) in :instance.data
        push!(@lget!(out, tf, DataFrame[]), df)
    end
    out
end

Base.first(ac::AssetCollection, a::AbstractAsset)::DataFrame =
    first(first(ac[a].instance).data)[2]

@doc """Makes a date range that spans the common minimum and maximum dates of the collection.

$(TYPEDSIGNATURES)

The `DateRange` function takes the following parameters:

- `ac`: an AssetCollection object which encapsulates a collection of assets.
- `tf` (optional): a TimeFrame object that represents a specific time frame. If not provided, the function will calculate the date range based on all time frames in the AssetCollection.
- `skip_empty` (optional, default is false): a boolean that indicates whether to skip empty data frames in the calculation of the date range.

"""
function TimeTicks.DateRange(ac::AssetCollection, tf=nothing; skip_empty=false)
    m = typemin(DateTime)
    M = typemax(DateTime)
    for ai in ac.data.instance
        df = first(values(ai.data))
        if skip_empty && isempty(df)
            continue
        end
        d_min = firstdate(df)
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

@doc """Checks that all assets in the universe match the cash currency.

$(TYPEDSIGNATURES)

The `iscashable` function takes the following parameters:

- `c`: an AbstractCash object which encapsulates a representation of cash.
- `ac`: an AssetCollection object which encapsulates a collection of assets.
"""
iscashable(c::AbstractCash, ac::AssetCollection) = begin
    for ai in ac
        if ai.asset.qc != nameof(c)
            return false
        end
    end
    return true
end

reset!(ac::AssetCollection) = begin
    ais = ac.data.instance
    foreach(eachindex(ais)) do idx
        ai = ais[idx]
        this_exc = exchange(ai)
        eid = exchangeid(this_exc)
        acc = account(this_exc)
        params = this_exc.params
        sandbox = issandbox(this_exc)
        ais[idx] = similar(ai; exc=getexchange!(eid, params; sandbox, account=acc))
    end
end

export AssetCollection, flatten, iscashable
