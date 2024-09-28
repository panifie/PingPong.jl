using .Lang: @lget!, @deassert, MatchString, @caller, Option
using .Instances: ohlcv_dict
using .Data: propagate_ohlcv!
import .Instances.ExchangeTypes: exchangeid, exchange
import .Instances.Exchanges: marketsid
import .Instruments: cash!, add!, sub!, addzero!, subzero!, freecash, cash
using .Misc: attr, setattr!
import .Misc: marginmode
using .OrderTypes: IncreaseTrade, ReduceTrade, SellTrade, ShortBuyTrade

baremodule LogStrategyLock end

const _STR_SYMBOLS_CACHE = Dict{String,Symbol}()
const _SYM_SYMBOLS_CACHE = Dict{Symbol,Symbol}()

@doc """ Retrieves the market identifiers for a given strategy type.

$(TYPEDSIGNATURES)

The `marketsid` function invokes the `ping!` function with the strategy type and `StrategyMarkets()` as arguments.
This function is used to fetch the market identifiers associated with a specific strategy type.
"""
marketsid(t::Type{<:S}) where {S<:Strategy} = invokelatest(ping!, t, StrategyMarkets())
marketsid(s::S) where {S<:Strategy} = begin
    ping!(typeof(s), StrategyMarkets())
end
Base.Broadcast.broadcastable(s::Strategy) = Ref(s)
@doc "Assets loaded by the strategy."
assets(s::Strategy) = universe(s).data.asset
inuniverse(a::AbstractAsset, s::Strategy) = a ∈ assets(s)
inuniverse(ai::AssetInstance, s::Strategy) = ai.asset ∈ assets(s)
inuniverse(sym::Symbol, s::Strategy) = begin
    for ai in s.universe
        if sym == bc(ai)
            return true
        end
    end
    return false
end
@doc "Strategy assets instance."
instances(s::Strategy) = universe(s).data.instance
# FIXME: this should return the Exchange, not the ExchangeID
@doc "Strategy exchange."
exchange(s::Strategy) = getexchange!(Symbol(exchangeid(s)); sandbox=s.sandbox, account=account(s))
function exchangeid(
    ::Union{<:S,Type{<:S}} where {S<:Strategy{X,N,E,R,C} where {X,N,R,C}}
) where {E<:ExchangeID}
    E
end
Exchanges.account(s::Strategy) = getfield(getfield(s, :config), :account)
Exchanges.accounts(s::Strategy) = Exchanges.accounts(exchange(s))
Exchanges.current_account(s::Strategy) = Exchanges.current_account(exchange(s))
function Exchanges.getexchange!(s::Type{<:Strategy})
    getexchange!(Symbol(exchangeid(s)); sandbox=issandbox(s), account=account(s))
end
Exchanges.issandbox(s::Strategy) = begin
    ans = s.sandbox
    @deassert ans == Exchanges.issandbox(exchange(s))
    ans
end
function Exchanges.issandbox(s::Type{<:Strategy})
    let mod = getproperty(Main, nameof(s))
        if hasproperty(mod, :SANDBOX)
            prop = getproperty(mod, :SANDBOX)
            if prop isa Bool
                prop
            elseif prop isa Ref{Bool}
                prop[]
            else
                @error "strategy: expected `SANDBOX` to be a boolean ref" prop
                execmode(s) != Paper()
            end
        else
            @warn "strategy: `SANDBOX` property not found"
            execmode(s) != Paper()
        end
    end
end
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
Misc.execmode(::Union{Type{S},S}) where {S<:Strategy{M}} where {M<:ExecMode} = M()

@doc """ Checks if the strategy's cash matches its universe.

$(TYPEDSIGNATURES)

The `iscashable` function checks if the cash of the strategy is cashable within the universe of the strategy.
It returns `true` if the cash is cashable, and `false` otherwise.
"""
coll.iscashable(s::Strategy) = coll.iscashable(s.cash, universe(s))
issim(::Strategy{M}) where {M<:ExecMode} = M == Sim
ispaper(::Strategy{M}) where {M<:ExecMode} = M == Paper
islive(::Strategy{M}) where {M<:ExecMode} = M == Live
@doc "The name of the strategy module."
Base.nameof(::Type{<:Strategy{<:ExecMode,N}}) where {N<:Symbol} = N
@doc "The name of the strategy module."
Base.nameof(s::Strategy) = typeof(s).parameters[2]
@doc "The strategy `AssetCollection`."
universe(s::Strategy) = getfield(s, :universe)
@doc "The `throttle` attribute determines the strategy polling interval."
throttle(s::Strategy) = attr(s, :throttle, Second(5))
@doc "The strategy `Config` attributes."
attrs(s::Strategy) = getfield(getfield(s, :config), :attrs)
@doc "`Symbol` representation of the strategy (name of the module)."
Base.Symbol(s::Strategy) = nameof(s)
Base.haskey(s::Strategy, k) = haskey(attrs(s), k)

@doc """ Resets the state of a strategy.

$(TYPEDSIGNATURES)

The `reset!` function is used to reset the state of a given strategy.
It empties the buy and sell orders, resets the holdings and assets, and optionally re-applies the strategy configuration defaults.
If the strategy is currently running, the reset operation is aborted with a warning.
"""
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
            nameof(exchange(s))
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
    abs = attr(s, :assets_bysym, nothing)
    if !isnothing(abs)
        empty!(abs)
    end
    ping!(s, ResetStrategy())
end
@doc """ Reloads OHLCV data for assets in the strategy universe.

$(TYPEDSIGNATURES)

The `reload!` function empties the data for each asset instance in the strategy's universe and then loads new data.
This is useful for refreshing the strategy's knowledge of the market state.
"""
reload!(s::Strategy) = begin
    for inst in universe(s).data.instance
        empty!(inst.data)
        load!(inst; reset=true)
    end
end
const config_fields = fieldnames(Config)
@doc "Set strategy defaults."
default!(s::Strategy) = nothing

@doc """ Fills the strategy with the specified timeframes.

$(TYPEDSIGNATURES)

This function fills the strategy with the specified timeframes. It first creates a set of timeframes and adds the strategy's timeframe, the timeframes from the strategy's configuration, and the timeframe attribute of the strategy. It then fills the universe of the strategy with these timeframes.
"""
Base.fill!(s::Strategy; kwargs...) = begin
    tfs = Set{TimeFrame}()
    push!(tfs, s.timeframe)
    push!(tfs, s.config.timeframes...)
    push!(tfs, attr(s, :timeframe, s.timeframe))
    uni = universe(s)
    coll.fill!(uni, tfs...; kwargs...)
    for ai in uni
        propagate_ohlcv!(ohlcv_dict(ai))
    end
end

_config_attr(s, k) = getfield(getfield(s, :config), k)

@doc """ Retrieves a property of a strategy.

$(TYPEDSIGNATURES)

This function checks if the property is directly on the strategy or the strategy's configuration.
If the property is not found, it checks the configuration's attributes.
"""
function Base.getproperty(s::Strategy, sym::Symbol)
    if hasfield(Strategy, sym)
        getfield(s, sym)
    else
        cfg = getfield(s, :config)
        if hasfield(Config, sym)
            getfield(cfg, sym)
        else
            getfield(cfg, :attrs)[sym]
        end
    end
end

@doc """ Retrieves a property of a strategy using a string key.

$(TYPEDSIGNATURES)

This function first gets the universe of the strategy and then retrieves the property using the string key.
"""
function Base.getproperty(s::Strategy, sym::String)
    uni = getfield(s, :universe)
    uni[MatchString(sym)]
end

@doc """ Generates the path for strategy logs.

$(TYPEDSIGNATURES)

The `logpath` function generates a path for storing strategy logs.
It takes the strategy and optional parameters for the name of the log file and additional path nodes.
The function checks if the directory for the logs exists and creates it if necessary.
It then returns the full path to the log file.
"""
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

@doc """ Retrieves the logs for a strategy.

$(TYPEDSIGNATURES)

The `logs` function collects and returns all the logs associated with a given strategy.
It fetches the logs from the directory specified in the strategy's path.
"""
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
Base.lock(s::Strategy) = begin
    @debug "strategy: locking" _module = LogStrategyLock @caller
    lock(getfield(s, :lock))
    @debug "strategy: locked" _module = LogStrategyLock @caller
end
Base.lock(f, s::Strategy) = begin
    @debug "strategy: locking" _module = LogStrategyLock @caller
    lock(f, getfield(s, :lock))
    @debug "strategy: locked" _module = LogStrategyLock @caller
end
Base.unlock(s::Strategy) = begin
    unlock(getfield(s, :lock))
    @debug "strategy: unlocked" _module = LogStrategyLock @caller
end
Base.islocked(s::Strategy) = islocked(getfield(s, :lock))
Base.float(s::Strategy) = cash(s).value
Base.get(s::Strategy, k::Symbol, def) = get(getfield(getfield(s, :config), :attrs), k, def)

@doc """ Creates a similar strategy with optional changes.

$(TYPEDSIGNATURES)

The `similar` function creates a new strategy that is similar to the given one.
It allows for optional changes to the mode, timeframe, and exchange.
The new strategy is created with the same self, margin mode, and universe as the original, but with a copy of the original's configuration.
"""
function Base.similar(s::Strategy; mode=s.mode, timeframe=s.timeframe, exc=exchange(s))
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

function symsdict(s::Strategy)
    @lock s @lget! attrs(s) :assets_bysym Dict{String,Option{AssetInstance}}()
end

@doc """
Retrieves an asset instance by symbol.

$(TYPEDSIGNATURES)

This function retrieves an asset instance by symbol `sym` from a strategy `s`. It first checks if the asset instance is already cached in the strategy's attributes. If not, it retrieves the asset instance from the strategy's universe. If the asset instance is not found, it returns `nothing`.

"""
function asset_bysym(s::Strategy, sym, dict_bysim=symsdict(s))
    k = string(sym)
    ai = get(dict_bysim, k, nothing)
    if isnothing(ai)
        ai = s[MatchString(k)]
        if ai isa AssetInstance
            dict_bysim[k] = ai
        end
    else
        ai
    end
end
