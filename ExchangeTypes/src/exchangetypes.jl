using Ccxt
using Python: Py, pybuiltins, pyconvert, Python, pyhasattr, pygetattr
using Python.PythonCall: pyisnone, pyisnull
using FunctionalCollections
using Lang: Option, waitfunc

include("exchangeid.jl")
include("exchange.jl")

export Exchange, ExchangeID, ExcPrecisionMode, exchanges, sb_exchanges, globalexchange!

function _doinit()
    waitfunc(Ccxt.isinitialized)
    @assert !pyisnull(ccxt[])
end
