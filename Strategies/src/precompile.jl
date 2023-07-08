using Lang: @preset, @precomp

module BareStrat
using ..Strategies
using ..ExchangeTypes
using ..ExchangeTypes.Ccxt: ccxt_exchange
using ..TimeTicks
using ..Strategies: AssetCollection
import .Strategies: ping!
using Misc: Sim, NoMargin
const NAME = :BaseStrat
const EXCID = ExchangeTypes.ExchangeID(:bybit)
const S{M} = Strategy{M,NAME,typeof(EXCID)}
const TF = tf"1m"
ping!(::S, args...; kwargs...) = nothing
function ping!(::Type{<:S}, config, ::LoadStrategy)
    Strategy(
        BareStrat,
        Sim(),
        NoMargin(),
        tf"1m",
        config[:exc],
        AssetCollection();
        config,
    )
end
end

@preset let
    using ..ExchangeTypes.Ccxt: ccxt_exchange
    @precomp Config()
    cfg = Config()
    cfg[:exc] = ExchangeTypes.Exchange(ccxt_exchange(:phemex))
    @precomp strategy!(BareStrat, cfg)
    s = strategy!(BareStrat, cfg)
    @precomp begin
        assets(s)
        instances(s)
        exchange(typeof(s))
        freecash(s)
        execmode(s)
        nameof(s)
        nameof(typeof(s))
        reset!(s)
        propertynames(s)
        s.attrs
        coll.iscashable(s)
        minmax_holdings(s)
        trades_count(s)
        orders(s, Buy)
        orders(s, Sell)
        show(devnull, s)
    end
end
