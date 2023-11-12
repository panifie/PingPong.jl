using .Lang: @lget!, @deassert, MatchString
import .Instances.ExchangeTypes: exchangeid, exchange
import .Instances.Exchanges: marketsid
import .Instruments: cash!, add!, sub!, addzero!, subzero!, freecash, cash
using .Misc: attr, setattr!
import .Misc: marginmode
using .OrderTypes: IncreaseTrade, ReduceTrade, SellTrade, ShortBuyTrade

marketsid(t::Type{<:Strategy}) = invokelatest(ping!, t, StrategyMarkets())
marketsid(s::Strategy) = ping!(typeof(s), StrategyMarkets())
Base.Broadcast.broadcastable(s::Strategy) = Ref(s)
@doc "Assets loaded by the strategy."
assets(s::Strategy) = universe(s).data.asset
@doc "Strategy assets instance."
instances(s::Strategy) = universe(s).data.instance
# FIXME: this should return the Exchange, not the ExchangeID
@doc "Strategy main exchange id."
exchange(s::S) where {S<:Strategy} = attr(s, :exc)
function exchangeid(
    ::Union{<:S,Type{<:S}} where {S<:Strategy{X,N,E} where {X,N}}
) where {E<:ExchangeID}
    E
end
Exchanges.issandbox(s::Strategy) = Exchanges.issandbox(exchange(s))
cash(s::Strategy) = getfield(s, :cash)
Instances.committed(s::Strategy) = getfield(s, :cash_committed)
@doc "Cash that is not committed, and therefore free to use for new orders."
freecash(s::Strategy) = cash(s) - s.cash_committed
@doc "Get the strategy margin mode."
function marginmode(
    ::Union{<:T,<:Type{<:T}}
) where {T<:Strategy{X,N,E,M} where {X,N,E}} where {M<:MarginMode}
    M()
end

@doc "Returns the strategy execution mode."
Misc.execmode(::Strategy{M}) where {M<:ExecMode} = M()

coll.iscashable(s::Strategy) = coll.iscashable(s.cash, universe(s))
issim(::Strategy{M}) where {M<:ExecMode} = M == Sim
ispaper(::Strategy{M}) where {M<:ExecMode} = M == Paper
islive(::Strategy{M}) where {M<:ExecMode} = M == Live
Base.nameof(::Type{<:Strategy{<:ExecMode,N}}) where {N} = N
Base.nameof(s::Strategy) = nameof(typeof(s))
universe(s::Strategy) = getfield(s, :universe)
throttle(s::Strategy) = attr(s, :throttle, Second(5))
attrs(s::Strategy) = getfield(getfield(s, :config), :attrs)

@doc "Resets strategy state.
`defaults`: if `true` reapply strategy config defaults."
function reset!(s::Strategy, config=false)
    let attrs = attrs(s)
        if haskey(attrs, :is_running) && attrs[:is_running][]
            @warn "Aborting reset because $(nameof(s)) is running in $(execmode(s)) mode!"
            return nothing
        end
    end
    for d in values(s.buyorders)
        empty!(d)
    end
    for d in values(s.sellorders)
        empty!(d)
    end
    empty!(s.holdings)
    for ai in universe(s)
        reset!(ai, Val(:full))
    end
    if config
        reset!(s.config)
    else
        let cfg = s.config
            cfg.exchange = nameof(exchange(s))
            cfg.mode = execmode(s)
            cfg.margin = marginmode(s)
            cfg.qc = nameof(cash(s))
            cfg.min_timeframe = s.timeframe
        end
    end
    default!(s)
    cash!(s.cash, s.config.initial_cash)
    cash!(s.cash_committed, 0.0)
    ping!(s, ResetStrategy())
end
@doc "Reloads ohlcv data for assets already present in the strategy universe."
reload!(s::Strategy) = begin
    for inst in universe(s).data.instance
        empty!(inst.data)
        load!(inst; reset=true)
    end
end
const config_fields = fieldnames(Config)
@doc "Set strategy defaults."
default!(s::Strategy) = nothing

Base.fill!(s::Strategy; kwargs...) = begin
    tfs = Set{TimeFrame}()
    push!(tfs, s.timeframe)
    push!(tfs, s.config.timeframes...)
    push!(tfs, attr(s, :timeframe, s.timeframe))
    coll.fill!(universe(s), tfs...; kwargs...)
end

_config_attr(s, k) = getfield(getfield(s, :config), k)
function Base.getproperty(s::Strategy, sym::Symbol)
    if sym == :attrs
        _config_attr(s, :attrs)
    elseif sym == :exchange
        _config_attr(s, :exchange)
    elseif sym == :path
        _config_attr(s, :path)
    elseif sym == :initial_cash
        _config_attr(s, :initial_cash)
    elseif sym == :min_size
        _config_attr(s, :min_size)
    elseif sym == :min_vol
        _config_attr(s, :min_vol)
    elseif sym == :qc
        _config_attr(s, :qc)
    elseif sym == :margin
        _config_attr(s, :margin)
    elseif sym == :leverage
        _config_attr(s, :leverage)
    elseif sym == :mode
        _config_attr(s, :mode)
    else
        getfield(s, sym)
    end
end

function logpath(s::Strategy; name="events", path_nodes...)
    dir = dirname(s.path)
    dirpath = if dir == ""
        pwd()
    else
        dirpath = joinpath(realpath(dirname(s.path)), "logs", path_nodes...)
        isdir(dirpath) || mkpath(dirpath)
        dirpath
    end
    joinpath(dirpath, string(replace(name, r".log$" => ""), ".log"))
end

function logs(s::Strategy)
    dirpath = joinpath(realpath(dirname(s.path)), "logs")
    collect(Iterators.flatten(walkdir(dirpath)))
end

function Base.propertynames(::Strategy)
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

Base.getindex(s::Strategy, k::MatchString) = getindex(s.universe, k)
Base.getindex(s::Strategy, k) = attr(s, k)
Base.setindex!(s::Strategy, v, k...) = setattr!(s, v, k...)
Base.lock(s::Strategy) = lock(getfield(s, :lock))
Base.lock(f, s::Strategy) = lock(f, getfield(s, :lock))
Base.unlock(s::Strategy) = unlock(getfield(s, :lock))
Base.islocked(s::Strategy) = islocked(getfield(s, :lock))
Base.float(s::Strategy) = cash(s).value

function Base.similar(
    s::Strategy;
    mode=s.mode,
    timeframe=s.timeframe,
    exc=Exchanges.getexchange!(s.exchange; sandbox=mode == Sim()),
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
