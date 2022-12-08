macro in_repl()
    quote
        @eval begin
            Misc.pypath!()
            an = Analysis
            using Plotting: plotone, @plotone
            using Misc: config, @margin!, @margin!!
        end
        exc = setexchange!(:kucoin)
    end
end

function user!()
    @eval include(joinpath(@__DIR__, "user.jl"))
    @eval using Misc: config
    @eval export results, exc, config
    @eval an = Analysis
    nothing
end
