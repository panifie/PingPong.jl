# NOTE: this constructor can't be revised, requires a restart
function Strategies.Strategy(
    self::Module,
    assets::Union{Dict,Iterable{String}};
    load_data=true,
    config::Config,
    mode=config.mode,
    margin=config.margin,
    sandbox=true,
    timeframe=config.min_timeframe,
)
    exc = getexchange!(config.exchange; sandbox)
    uni = if isempty(assets)
        AssetCollection()
    else
        AssetCollection(assets; load_data, timeframe=string(timeframe), exc, margin)
    end
    s = Strategy(self, mode, margin, timeframe, exc, uni; config)
    mode_k = if mode == Sim()
        :sim
    elseif mode == Paper()
        :paper
    else
        :live
    end
    for f in getproperty(Strategies.STRATEGY_LOAD_CALLBACKS, mode_k)
        f(s)
    end
    s
end
