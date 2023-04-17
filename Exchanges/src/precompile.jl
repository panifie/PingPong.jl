using Lang: wait, @preset, @precomp

@preset let
    id = :bybit
    using Python: Python
    using Ccxt: exc_finalizers
    @assert Python.isinitialized_async(Python.gpa)
    @precomp let
        finalize(getexchange!(id; markets=:force).py)
        finalize(getexchange!(id; markets=:yes, sandbox=false).py)
    end
    qc = "USDT"
    pair = "BTC/USDT"
    emptycaches!()
    e = getexchange!(id; markets=:yes)
    @precomp let
        futures(e)
        timestamp(e)
        check_timeout(e)
        tickers(e, qc; min_vol=1e4)
        tickers(e, qc; min_vol=1e4, with_margin=true)
        tickers(e, qc; min_vol=1e4, with_futures=true)
        tickers(e, qc; min_vol=1e4, with_leverage=:yes)
        tickers(e, qc; min_vol=1e4, with_leverage=:only)
        tickers(e, qc; min_vol=1e4, with_leverage=:from)
        market!(pair, e)
        ticker!(pair, e)
        is_pair_active(pair, e)
        market_precision(pair, e)
        market_limits(pair, e)
        market_fees(pair, e)
    end
    finalize(e.py)
    wait.(exc_finalizers)
    emptycaches!()
end
