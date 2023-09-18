using Lang: @lget!, @deassert, MatchString
using Misc: attr, setattr!
import Instances.ExchangeTypes: exchangeid, exchange
import Misc: reset!, Long, Short, attrs
import Instruments: cash!, add!, sub!, addzero!, subzero!, freecash

using OrderTypes: IncreaseTrade, ReduceTrade, SellTrade, ShortBuyTrade, ordersdefault!

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
Exchanges.issandbox(s::Strategy) = Exchanges.issandbox(attr(s, :exc))
@doc "Cash that is not committed, and therefore free to use for new orders."
freecash(s::Strategy) = s.cash - s.cash_committed
@doc "Get the strategy margin mode."
Misc.marginmode(::Strategy{X,N,E,M}) where {X,N,E,M<:MarginMode} = M()

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

@doc "Resets strategy state.
`defaults`: if `true` reapply strategy config defaults."
function reset!(s::Strategy, config=false)
    let attrs = attrs(s)
        if (haskey(attrs, :paper_running) && attrs[:paper_running][]) ||
            (haskey(attrs, :live_running) && attrs[:live_running][])
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
    config && reset!(s.config)
    default!(s)
    ordersdefault!(s)
    cash!(s.cash, s.config.initial_cash)
    cash!(s.cash_committed, 0.0)
    s.config.exchange = nameof(exchange(s))
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
default!(s::Strategy) = begin
    setattr!(s, :throttle, Second(5))
end

Base.fill!(s::Strategy; kwargs...) = begin
    tfs = Set{TimeFrame}()
    push!(tfs, s.timeframe)
    push!(tfs, s.config.timeframes...)
    push!(tfs, attr(s, :timeframe, s.timeframe))
    coll.fill!(universe(s), tfs...; kwargs...)
end

function Base.getproperty(s::Strategy, sym::Symbol)
    if sym == :attrs
        attrs(s)
    elseif sym == :exchange
        attr(s, :exchange)
    elseif sym == :path
        attr(s, :path)
    elseif sym == :initial_cash
        attr(s, :initial_cash)
    elseif sym == :min_size
        attr(s, :min_size)
    elseif sym == :min_vol
        attr(s, :min_vol)
    elseif sym == :qc
        attr(s, :qc)
    elseif sym == :margin
        attr(s, :margin)
    elseif sym == :leverage
        attr(s, :leverage)
    elseif sym == :mode
        attr(s, :mode)
    else
        getfield(s, sym)
    end
end
attrs(s::Strategy) = getfield(getfield(s, :config), :attrs)

function logpath(s::Strategy; name="events", path_nodes...)
    dirpath = joinpath(realpath(dirname(s.path)), "logs", path_nodes...)
    isdir(dirpath) || mkpath(dirpath)
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
Base.setindex!(s::Strategy, v, k) = setattr!(s, k, v)
Base.lock(s::Strategy) = lock(getfield(s, :lock))
Base.lock(f, s::Strategy) = lock(f, getfield(s, :lock))
Base.unlock(s::Strategy) = unlock(getfield(s, :lock))
Base.islocked(s::Strategy) = islocked(getfield(s, :lock))
