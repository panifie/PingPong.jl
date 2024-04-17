using .Misc.Lang: PrecompileTools, @preset, @precomp
using .Misc: @skipoffline

@preset let
    Python.py_start_loop()
    pair = "BTC/USDT"
    using .Data: zinstance
    using Exchanges.ExchangeTypes: _closeall
    tmp_zi = zinstance(mktempdir())
    @warn "Precompilation of the `Fetch` module does api calls!"
    # ENV["JULIA_DEBUG"] = "Fetch"
    try
        let e = getexchange!(:cryptocom)
            @precomp @skipoffline begin
                fetch_ohlcv(e, "1d", [pair]; zi=tmp_zi, from=-100, to=-10)
                fetch_candles(e, "1d", [pair]; from=-100, to=-10)
            end
        end
        _closeall()
    finally
        if hasproperty(tmp_zi.store, :a)
            rm(tmp_zi.store.a)
        end
    end
    Python.py_stop_loop()
end
