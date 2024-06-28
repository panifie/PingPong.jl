struct OHLCVUpdated{E} <: ExchangeEvent{E}
    tag::Symbol
    data::NamedTuple
end
