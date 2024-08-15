using .Executors.Instruments.Derivatives: Derivative
using .Exchanges.ExchangeTypes: eids, Ccxt
import .Exchanges.ExchangeTypes: _has
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

function time_in_force_key(::Exchange{<:eids(:phemex, :bybit)}, ::AbstractAsset)
    @pyconst "timeInForce"
end
function time_in_force_value(::Exchange{<:eids(:phemex)}, ::Option{<:AbstractAsset}, v)
    _tif_value(v)
end
time_in_force_value(::Exchange, _, v) = v

const _BINANCE_EXC = Exchange{<:eids(:binance, :binanceusdm, :binancecoin)}
function first(exc::_BINANCE_EXC, syms::Vararg{Union{Symbol,String}})
    fs = first(syms) |> string
    if endswith(fs, "Ws")
        invoke(first, Tuple{Exchange,Vararg{Symbol}}, exc, syms[2:end]...)
    else
        invoke(first, Tuple{Exchange,Vararg{Symbol}}, exc, syms...)
    end
end

Ccxt.issupported(exc::_BINANCE_EXC, k) = !isnothing(first(exc, Symbol(k)))

function _has(exc::Exchange{ExchangeID{:phemex}}, sym::Symbol)
    if sym == :watchBalance
        true
    else
        invoke(_has, Tuple{Exchange,Symbol}, exc, sym)
    end
end

function _has(exc::Exchange{ExchangeID{:phemex}}, syms::Vararg{Symbol})
    any(v -> v == :watchBalance, syms) ||
        invoke(_has, Tuple{Exchange,Vararg{Symbol}}, exc, syms...)
end
