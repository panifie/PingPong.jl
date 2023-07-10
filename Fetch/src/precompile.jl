using .Misc.Lang: SnoopPrecompile, @preset, @precomp

@preset let
    pair = "BTC/USDT"
    using .Data: zilmdb
    tmp_zi = zilmdb(mktempdir())
    @warn "Precompilation of the `Fetch` module does api calls!"
    try
        let e = getexchange!(:binance)
            @precomp begin
                fetch_ohlcv(e, "1d", [pair]; zi=tmp_zi, from=-100, to=-10)
                fetch_candles(e, "1d", [pair]; from=-100, to=-10)
            end
            finalize(e)
        end
    finally
        rm(tmp_zi.store.a)
    end
end
