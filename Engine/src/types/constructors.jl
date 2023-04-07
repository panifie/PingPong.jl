using Exchanges: market_fees, market_limits, market_precision, getexchange!
using Instances
using Strategies
using Collections

function Instances.AssetInstance(a; data, exc, min_amount=1e-15)
    limits = market_limits(a.raw, exc; default_amount=(min=min_amount, max=Inf))
    precision = market_precision(a.raw, exc)
    fees = market_fees(a.raw, exc)
    AssetInstance(a, data, exc; limits, precision, fees)
end
function Instances.AssetInstance(s::S, t::S, e::S) where {S<:AbstractString}
    a = parse(AbstractAsset, s)
    tf = convert(TimeFrame, t)
    exc = getexchange!(Symbol(e))
    data = Dict(tf => load(zi, exc.name, a.raw, t))
    AssetInstance(a, data, exc)
end

function Strategies.Strategy(
    self::Module, assets::Union{Dict,Iterable{String}}; mode=Sim, config::Config
)
    exc = getexchange!(config.exchange)
    timeframe = @something self.TF config.min_timeframe first(config.timeframes)
    uni = AssetCollection(assets; timeframe=string(timeframe), exc)
    Strategy(self, mode, timeframe, exc, uni; config)
end

function Base.similar(
    s::Strategy, mode=s.mode, timeframe=s.timeframe, exc=getexchange!(s.exchange)
)
    s = Strategy(
        s.self, typeof(mode), timeframe, exc, similar(s.universe); config=copy(s.config)
    )
end
