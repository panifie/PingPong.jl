# Use
#    @warnpcfail precompile(args...)
# if you want to be warned when a precompile directive fails
macro warnpcfail(ex::Expr)
    modl = __module__
    file = __source__.file === nothing ? "?" : String(__source__.file)
    line = __source__.line
    quote
        $(esc(ex)) || @warn """precompile directive
     $($(Expr(:quote, ex)))
 failed. Please report an issue in $($modl) (after checking for duplicates) or remove this directive.""" _file=$file _line=$line
    end
end


function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    isdefined(BacktestCLI, Symbol("##fetch#1")) && precompile(Tuple{BacktestCLI.var"##fetch#1", String, String, String, String, Bool, String, typeof(BacktestCLI.fetch), String, Vararg{String}})
    isdefined(BacktestCLI, Symbol("#fetch##kw")) && precompile(Tuple{BacktestCLI.var"#fetch##kw", NamedTuple{(:exchange,), Tuple{String}}, typeof(BacktestCLI.fetch), String, Vararg{String}})
    isdefined(BacktestCLI, Symbol("#fetch##kw")) && precompile(Tuple{BacktestCLI.var"#fetch##kw", NamedTuple{(:exchange,), Tuple{String}}, typeof(BacktestCLI.fetch), String})
end
