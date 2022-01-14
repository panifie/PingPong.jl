macro in_repl()
    quote
        @eval begin
            using Backtest
            Backtest.Misc.pypath!()
            an = Backtest.Analysis
            using Backtest.Plotting: plotone, @plotone
            using Backtest.Misc: options, @margin!, @margin!!
        end
        exc = setexchange!(:kucoin)
    end
end
