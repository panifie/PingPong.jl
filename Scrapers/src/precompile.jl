using .Lang: @precomp, @preset
@preset let
    pairs = ["eth", "btc"]
    qc = "USDT"
    HTTP_PARAMS[:headers] = [("Connection", "Close")]
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
    Pbar.@pbstop!
    empty!(Data.zcache)
    HTTP.Connections.closeall() # This should work but doesn't
end
