eids(ids...) = Union{((ExchangeID{i}) for i in ids)...}

time_in_force_key(::Exchange{<:(eids(:phemex, :bybit))}) = @pyconst "timeInForce"
time_in_force_value(::Exchange{<:(eids(:phemex, :bybit))}, v) =
    @pystr if v == "PO"
        "PostOnly"
    elseif v == "FOK"
        "FillOrKill"
    elseif v == "IOC"
        "ImmediateOrCancel"
    elseif v == "GTC"
        "GoodTillCancel"
    else
        "GoodTillCancel"
    end
