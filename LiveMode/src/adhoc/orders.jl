time_in_force_key(::Exchange{ExchangeId{:phemex}}) = "timeInForce"
time_in_force_value(::Exchange{ExchangeId{:phemex}}, v) =
    if v == "PO"
        "PostOnly"
    elseif v == "FOK"
        "FillOrKill"
    elseif v == "IOC"
        "ImmediateOrCancel"
    elseif v == "GTC"
        "GoodTillCancel"
    end
