using .Executors.Instruments.Derivatives: Derivative
using .Exchanges.ExchangeTypes: eids, Ccxt
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

time_in_force_key(::Exchange{<:eids(:phemex, :bybit)}, ::AbstractAsset) = @pyconst "timeInForce"
time_in_force_value(::Exchange{<:eids(:phemex)}, ::Option{<:AbstractAsset}, v) = _tif_value(v)
time_in_force_value(::Exchange, _, v) = v

const _BINANCE_EXC = Exchange{<:eids(:binance, :binanceusdm, :binancecoin)}
first(exc::_BINANCE_EXC, syms::Vararg{Union{Symbol,String}}) = begin
    fs = first(syms) |> string
    if endswith(fs, "Ws") && (fs != "createOrderWs" && exchangeid(exc) != ExchangeID{:binance})
        invoke(first, Tuple{Exchange,Vararg{Symbol}}, exc, syms[2:end]...)
    else
        invoke(first, Tuple{Exchange,Vararg{Symbol}}, exc, syms...)
    end
end

Ccxt.issupported(exc::_BINANCE_EXC, k) = !isnothing(first(exc, Symbol(k)))
