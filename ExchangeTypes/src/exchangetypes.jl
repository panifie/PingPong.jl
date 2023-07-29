using Ccxt
using Python: Py, pybuiltins, pyconvert, Python, pyhasattr, pygetattr
using Python.PythonCall: pyisnone, pyisnull
using FunctionalCollections
using Lang: Option, waitfunc

include("exchangeid.jl")
include("exchange.jl")

export Exchange,
    ExchangeID, ExcPrecisionMode, exchange, exchanges, sb_exchanges, globalexchange!, has

function _doinit()
    waitfunc(Ccxt.isinitialized)
    @assert !pyisnull(ccxt[])
end
