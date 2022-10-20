should_precompile =   true


# Don't edit the following! Instead change the script for `snoop_bot`.
ismultios = true
ismultiversion = false
# precompile_enclosure
@static if !should_precompile
    # nothing
elseif !ismultios && !ismultiversion
    @static if isfile(joinpath(@__DIR__, "../deps/SnoopCompile/precompile/precompile_Backtest.jl"))
        include("../deps/SnoopCompile/precompile/precompile_Backtest.jl")
        _precompile_()
    end
else
    @static if Sys.islinux() 
    @static if isfile(joinpath(@__DIR__, "../deps/SnoopCompile/precompile/linux/precompile_Backtest.jl"))
        include("../deps/SnoopCompile/precompile/linux/precompile_Backtest.jl")
        _precompile_()
    end
else 
    end

end # precompile_enclosure
