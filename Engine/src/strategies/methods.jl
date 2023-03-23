@doc "Assets loaded by the strategy."
assets(s::Strategy) = s.universe.data.asset
@doc "Strategy assets instance."
instances(s::Strategy) = s.universe.data.instance
@doc "Strategy main exchange id."
exchange(t::Type{<:Strategy}) = t.parameters[3].parameters[1]

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
    empty!(s.orders)
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
@doc "Set strategy defaults."
default!(::Strategy) = begin end
