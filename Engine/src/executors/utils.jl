@doc "Creates a context within the available data loaded into the strategy universe with the smallest timeframe available."
Types.Context(s::Strategy{<:ExecMode}) = begin
    dr = DateRange(s.universe)
    Types.Context(execmode(s), dr)
end
