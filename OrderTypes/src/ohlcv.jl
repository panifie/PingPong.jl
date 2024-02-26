struct OHLCV{E<:ExchangeID,A<:AbstractAsset,C} <: ExchangeEvent{E}
    v::C
end
