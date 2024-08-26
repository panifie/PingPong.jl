using .Exchanges: issandbox

# NOTE: this constructor can't be revised, requires a restart
@doc """Initializes a Strategy object in the Strategies module.

$(TYPEDSIGNATURES)

The `Strategy` function takes the following parameters:

- `self`: a Module object representing the current module.
- `assets`: a Union of a dictionary or iterable of strings representing the assets to be included in the strategy.
- `load_data` (optional, default is true): a boolean indicating whether to load data for the assets.
- `config`: a Config object representing the configuration settings for the strategy.
- `mode` (optional, default is config.mode): a mode setting for the strategy.
- `margin` (optional, default is config.margin): a margin setting for the strategy.
- `sandbox` (optional, default is true): a boolean indicating whether to run the strategy in a sandbox environment.
- `timeframe` (optional, default is config.min_timeframe): a timeframe setting for the strategy.

The function initializes a Strategy object with the specified settings and assets.

"""
function Strategies.Strategy(
    self::Module,
    assets::Union{Dict,Iterable{String}};
    load_data=false,
    config::Config,
    params=config.params,
    account=config.account,
    mode=config.mode,
    margin=config.margin,
    sandbox=config.sandbox,
    timeframe=config.min_timeframe,
)
    setproperty!(config, :sandbox, sandbox)
    setproperty!(config, :mode, mode)
    setproperty!(config, :margin, margin)
    setproperty!(config, :min_timeframe, timeframe)
    exc = getexchange!(config.exchange, params; sandbox, account)
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
