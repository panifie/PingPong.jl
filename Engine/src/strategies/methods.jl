using Lang: @lget!

Base.Broadcast.broadcastable(s::Strategy) = Ref(s)
@doc "Assets loaded by the strategy."
assets(s::Strategy) = s.universe.data.asset
@doc "Strategy assets instance."
instances(s::Strategy) = s.universe.data.instance
@doc "Strategy main exchange id."
exchange(t::Type{<:Strategy}) = t.parameters[3].parameters[1]
@doc "Cash that is not committed, and therefore free to use for new orders."
freecash(s::Strategy) = s.cash - s.cash_committed

@doc "Returns the strategy execution mode."
Misc.execmode(::Strategy{M}) where {M<:ExecMode} = M()

@doc "Creates a context within the available data loaded into the strategy universe with the smallest timeframe available."
Types.Context(s::Strategy{<:ExecMode}) = begin
    dr = DateRange(s.universe)
    Types.Context(execmode(s), dr)
end

coll.iscashable(s::Strategy) = coll.iscashable(s.cash, s.universe)
Base.nameof(t::Type{<:Strategy}) = t.parameters[2]
Base.nameof(s::Strategy) = nameof(typeof(s))

@doc "Resets strategy."
reset!(s::Strategy) = begin
    empty!(s.buyorders)
    empty!(s.sellorders)
    empty!(s.holdings)
    for ai in s.universe
        empty!(ai.history)
        cash!(ai.cash, 0.0)
        cash!(ai.cash_committed, 0.0)
    end
    cash!(s.cash, s.config.initial_cash)
    cash!(s.cash_committed, 0.0)
end
@doc "Reloads ohlcv data for assets already present in the strategy universe."
reload!(s::Strategy) = begin
    for inst in s.universe.data.instance
        empty!(inst.data)
        load!(inst; reset=true)
    end
end
const config_fields = fieldnames(Config)
@doc "Set strategy defaults."
default!(::Strategy) = begin end
Base.fill!(s::Strategy) = coll.fill!(s.universe, s.timeframe, s.config.timeframes)
function Base.getproperty(s::Strategy, sym::Symbol)
    if sym == :attrs
        getfield(s, :config).attrs
    elseif sym == :exchange
        getfield(s, :config).exchange
    elseif sym == :path
        getfield(s, :config).path
    elseif sym == :initial_cash
        getfield(s, :config).initial_cash
    elseif sym == :min_size
        getfield(s, :config).min_size
    elseif sym == :min_vol
        getfield(s, :config).min_vol
    elseif sym == :qc
        getfield(s, :config).qc
    elseif sym == :mode
        getfield(s, :config).mode
    else
        getfield(s, sym)
    end
end
function Base.propertynames(s::Strategy)
    (
        fieldnames(Strategy)...,
        :attrs,
        :exchange,
        :path,
        :initial_cash,
        :min_size,
        :min_vol,
        :qc,
        :mode,
        :config,
    )
end
function Base.similar(
    s::Strategy, mode=s.mode, timeframe=s.timeframe, exc=getexchange!(s.exchange)
)
    s = Strategy(
        s.self, typeof(mode), timeframe, exc, similar(s.universe); config=copy(s.config)
    )
end
