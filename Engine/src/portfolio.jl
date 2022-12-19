using Base.Enums: namemap
using DataFrames, DataFramesMeta
@doc "A collection of assets instances, indexed by asset and exchange identifiers."
struct Portfolio1
    data::DataFrame
    function Portfolio1(
        df=DataFrame(; exchange=ExchangeID[], asset=Asset[], instance=AssetInstance[]),
    )
        new(df)
    end
    function Portfolio1(instances::Iterable{<:AssetInstance})
        DataFrame(
            (; exchange=inst.exchange[].sym, asset=inst.asset, instance=inst) for
            inst ∈ instances;
            copycols=false,
        ) |> Portfolio1
    end
    function Portfolio1(
        assets::Union{Iterable{String},Iterable{<:Asset}};
        timeframe="15m",
        exc::Exchange=exc,
    )
        if eltype(assets) == String
            assets = [Asset(name) for name ∈ assets]
        end
        tf = convert(TimeFrame, timeframe)
        getInstance(ast::Asset) = begin
            data = Dict(tf => load_pair(zi, exc.name, ast.raw, timeframe))
            AssetInstance(ast, data, exc)
        end
        instances = [getInstance(ast) for ast ∈ assets]
        Portfolio1(instances)
    end
end
Portfolio = Portfolio1

@enum PortfolioColumn exchange = 1 asset = 2 instance = 3
const PortfolioTypes =
    Dict([exchange => ExchangeID, asset => Asset, instance => AssetInstance])
const PortfolioColumns4 = PortfolioTypes |> sort |> keys .|> Symbol
PortfolioColumns = PortfolioColumns4
const PortfolioRow =
    @NamedTuple{exchange::ExchangeID, asset::Asset, instance::AssetInstance}

using Pairs: isbase, isquote
Base.getindex(pf::Portfolio, i::ExchangeID) = @view pf.data[pf.data.exchange.==i, :]
Base.getindex(pf::Portfolio, i::Asset) = @view pf.data[pf.data.asset.==i, :]
Base.getindex(pf::Portfolio, i::String) = @view pf.data[pf.data.asset.==i, :]

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
    pf::Portfolio;
    b::Union{Symbol,Nothing}=nothing,
    q::Union{Symbol,Nothing}=nothing,
    e::Union{Symbol,Nothing}=nothing,
)
    idx = bqe(pf.data, b, q, e)
    @view pf.data[idx, :]
end

function Base.display(pf::Portfolio; full=false)
    limit = full ? length(pf.data) : displaysize(stdout)[1]
    df_out = DataFrame(
        begin
            row = @view pf.data[n, :]
            (; cash=row.instance.cash, name=row.asset.raw, exchange=row.exchange.sym)
        end for n ∈ 1:limit-1
    )
    Base.display(df_out)
end

export Portfolio
