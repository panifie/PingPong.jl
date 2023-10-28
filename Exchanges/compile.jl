using Exchanges
using Exchanges.Python
using Exchanges:
    emptycaches!,
    futures,
    tickers,
    market!,
    ticker!,
    is_pair_active,
    market_precision,
    market_limits,
    market_fees
id = :okx
@assert Python.isinitialized_async(Python.gpa)
Python.py_stop_loop()
Python.py_start_loop()
getexchange!(id; markets=:force).py
getexchange!(id; markets=:yes, sandbox=false).py
ExchangeTypes._closeall()
emptycaches!()
qc = "USDT"
pair = "BTC/USDT"
e = getexchange!(id; markets=:yes)
futures(e)
timestamp(e)
check_timeout(e)
tickers(e, qc; min_vol=0.0, verbose=false)
tickers(e, qc; min_vol=-1.0, with_margin=true, verbose=false)
tickers(e, qc; min_vol=-0.0, with_leverage=:yes, verbose=false)
tickers(e, qc; min_vol=-1.0, with_leverage=:only, verbose=false)
tickers(e, qc; min_vol=-1.0, with_leverage=:from)
market!(pair, e)
ticker!(pair, e; func=e.fetchTicker)
is_pair_active(pair, e)
market_precision(pair, e)
market_limits(pair, e)
market_fees(pair, e)
ExchangeTypes._closeall()
emptycaches!()
Python.py_stop_loop()
