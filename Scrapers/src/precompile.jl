using Lang: @precomp, @preset
@preset let
    pairs = ["eth", "btc"]
    qc = "USDT"
    @precomp begin
        _doinit()
        try
            BinanceData.binanceload(pairs; quote_currency=qc)
        catch e
            display(e)
        end
        try
            BybitData.bybitload(pairs; quote_currency=qc)
        catch e
            display(e)
        end
    end
    empty!(Data.zcache)
end
