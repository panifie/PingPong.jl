macro in_repl()
    quote
        @eval begin
            Backtest.Misc.pypath!()
            an = Backtest.Analysis
            using Backtest.Plotting: plotone, @plotone
            using Backtest.Misc: config, @margin!, @margin!!
        end
        exc = setexchange!(:kucoin)
    end
end

function user!()
    @eval include(joinpath(@__DIR__, "user.jl"))
    @eval using .Misc: config
    @eval export results, exc, config
end
