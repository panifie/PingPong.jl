macro in_repl()
    quote
        @eval an = Backtest.Analysis
        copy!(exc, Backtest.Exchanges.getexchange(:kucoin))
        exckeys!(exc, values(Backtest.Exchanges.kucoin_keys())...)
        zi = ZarrInstance()
        exc, zi
    end
end
