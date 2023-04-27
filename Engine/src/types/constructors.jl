function Instances.AssetInstance(a; data, exc, margin, min_amount=1e-15)
    limits = market_limits(a.raw, exc; default_amount=(min=min_amount, max=Inf))
    precision = market_precision(a.raw, exc)
    fees = market_fees(a.raw, exc)
    AssetInstance(a, data, exc, margin; limits, precision, fees)
end
function Instances.AssetInstance(s::S, t::S, e::S, m::S) where {S<:AbstractString}
    a = parse(AbstractAsset, s)
    tf = convert(TimeFrame, t)
    exc = getexchange!(Symbol(e))
    margin = if m == "isolated"
        Isolated()
    elseif m == "cross"
        Cross()
    else
        NoMargin()
    end
    data = Dict(tf => load(zi, exc.name, a.raw, t))
    AssetInstance(a, data, exc, margin)
end

# NOTE: this constructor can't be revised, requires a restart
function Strategies.Strategy(
    self::Module,
    assets::Union{Dict,Iterable{String}};
    load_data=true,
    config::Config,
    mode=config.mode,
    margin=config.margin,
)
    exc = getexchange!(config.exchange)
    timeframe = @something self.TF config.min_timeframe first(config.timeframes)
    uni = AssetCollection(assets; load_data, timeframe=string(timeframe), exc, margin)
    Strategy(self, mode, margin, timeframe, exc, uni; config)
end

function Base.similar(
    s::Strategy, mode=s.mode, timeframe=s.timeframe, exc=getexchange!(s.exchange)
)
    s = Strategy(
        s.self, typeof(mode), timeframe, exc, similar(s.universe); config=copy(s.config)
    )
end
