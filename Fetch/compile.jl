using Fetch
using Fetch.Python
using Fetch.Data
using Fetch.Exchanges

Python.py_stop_loop()
Python.py_start_loop()
pair = "BTC/USDT"
using .Data: zinstance
using Exchanges.ExchangeTypes: _closeall
tmp_zi = zinstance(mktempdir())
atexit(() -> rm(tmp_zi.store.a))
e = getexchange!(:cryptocom)
fetch_ohlcv(e, "1d", [pair]; zi=tmp_zi, from=-100, to=-10)
fetch_candles(e, "1d", [pair]; from=-100, to=-10)
_closeall()
Python.py_stop_loop()
