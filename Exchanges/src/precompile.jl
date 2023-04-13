using Lang: wait, @preset, @precomp

@preset let
    id = :bybit
    using Python: Python
    @assert Python.isinitialized_async(Python.gpa)
    @precomp begin
        # using ExchangeTypes # ensure ccxt is loaded
        getexchange!(id; markets=:force)
        getexchange!(id; markets=:yes, sandbox=false)
    end
    qc = "USDT"
    pair = "BTC/USDT"
    e = getexchange!(id; markets=:yes)
    @precomp begin
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
        market_precision(pair, e)
        market_limits(pair, e)
        market_fees(pair, e)
        is_pair_active(pair, e)
    end
end
