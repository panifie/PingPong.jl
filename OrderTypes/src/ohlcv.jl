struct OHLCVUpdated{E} <: ExchangeEvent{E}
    tag::Symbol
    group::Symbol
    data::NamedTuple
end
