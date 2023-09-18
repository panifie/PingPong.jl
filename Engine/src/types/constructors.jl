# NOTE: this constructor can't be revised, requires a restart
function Strategies.Strategy(
    self::Module,
    assets::Union{Dict,Iterable{String}};
    load_data=true,
    config::Config,
    mode=config.mode,
    margin=config.margin,
    sandbox=true,
)
    exc = getexchange!(config.exchange; sandbox)
    timeframe = @something self.TF config.min_timeframe first(config.timeframes)
    uni = AssetCollection(assets; load_data, timeframe=string(timeframe), exc, margin)
    s = Strategy(self, mode, margin, timeframe, exc, uni; config)
    for funcs in values(Strategies.STRATEGY_LOAD_CALLBACKS)
        for f in funcs
            f(s)
        end
    end
    s
end

function Base.similar(
    s::Strategy;
    mode=s.mode,
    timeframe=s.timeframe,
    exc=getexchange!(s.exchange; sandbox=mode == Sim()),
)
    s = Strategy(
        s.self,
        mode,
        marginmode(s),
        timeframe,
        exc,
        similar(universe(s));
        config=copy(s.config),
    )
end
