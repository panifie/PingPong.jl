struct Balance{E<:ExchangeID,K,V} <: ExchangeEvent{E}
    v::Dict{K,V}
end
