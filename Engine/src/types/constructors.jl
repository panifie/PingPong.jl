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
