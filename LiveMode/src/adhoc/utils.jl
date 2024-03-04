using .Executors.Instruments.Derivatives: Derivative
using .Exchanges.ExchangeTypes: eids
import Base.first

_tif_value(v) = @pystr if v == "PO"
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

time_in_force_key(::Exchange{<:(eids(:phemex, :bybit))}, ::AbstractAsset) = @pyconst "timeInForce"
time_in_force_value(::Exchange{<:(eids(:phemex))}, ::Option{<:AbstractAsset}, v) = _tif_value(v)
time_in_force_value(::Exchange, _, v) = v
