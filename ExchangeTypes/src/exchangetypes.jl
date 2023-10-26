using Ccxt
using Ccxt: Python
using .Python: Py, pybuiltins, pyconvert, pyhasattr, pygetattr, pyisnone, pyisnull
using FunctionalCollections
using Ccxt.Misc.Lang: Option, waitfunc

include("exchangeid.jl")
include("exchange.jl")

export Exchange,
    ExchangeID,
    EIDType,
    ExcPrecisionMode,
    exchange,
    exchangeid,
    exchanges,
    sb_exchanges,
    globalexchange!,
    has

function _doinit()
    waitfunc(Ccxt.isinitialized)
    @assert !pyisnull(ccxt[])
end
