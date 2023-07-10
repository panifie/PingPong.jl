using Lang: wait, @preset, @precomp

@preset let
    id = :kucoin
    using Python: Python
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
    end
    finalize(e.py)
    emptycaches!()
end
