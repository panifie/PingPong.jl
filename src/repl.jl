macro in_repl()
    quote
        @eval begin
            using Backtest
            Backtest.Misc.pypath!()
            an = Backtest.Analysis
            using Backtest.Plotting: plotone, @plotone
            using Backtest.Misc: options, @margin!, @margin!!
        end
        copy!(exc, Backtest.Exchanges.getexchange(:kucoin))
        exckeys!(exc, values(Backtest.Exchanges.kucoin_keys())...)
        zi = ZarrInstance()
        exc, zi
    end
end
