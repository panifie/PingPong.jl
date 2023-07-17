using .Misc.Lang: SnoopPrecompile, @preset, @precomp

@preset let
    pair = "BTC/USDT"
    using .Data: zilmdb
    using Exchanges.ExchangeTypes: _closeall
    tmp_zi = zilmdb(mktempdir())
    @warn "Precompilation of the `Fetch` module does api calls!"
    try
        let e = getexchange!(:okx)
            @precomp begin
                fetch_ohlcv(e, "1d", [pair]; zi=tmp_zi, from=-100, to=-10)
                fetch_candles(e, "1d", [pair]; from=-100, to=-10)
            end
        end
        _closeall()
    finally
        rm(tmp_zi.store.a)
    end
end
