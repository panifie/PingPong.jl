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
    isdefined(Backtest, Symbol("##_get_zarray#11")) && precompile(Tuple{Backtest.Data.var"##_get_zarray#11", Type, Bool, Bool, typeof(Backtest.Data._get_zarray), Backtest.Data.ZarrInstance, String, Tuple{Int64, Int64}})
    isdefined(Backtest, Symbol("##_save_pair#12")) && precompile(Tuple{Backtest.Data.var"##_save_pair#12", String, Type, Int64, Int64, Bool, Bool, typeof(Backtest.Data._save_pair), Backtest.Data.ZarrInstance, String, Float64, DataFrames.DataFrame})
    isdefined(Backtest, Symbol("#_fetch_one_pair##kw")) && precompile(Tuple{Backtest.Exchanges.var"#_fetch_one_pair##kw", NamedTuple{(:from, :to), Tuple{Float64, String}}, typeof(Backtest.Exchanges._fetch_one_pair), PyCall.PyObject, Backtest.Data.ZarrInstance, String, String})
    isdefined(Backtest, Symbol("#_fetch_with_delay##kw")) && precompile(Tuple{Backtest.Exchanges.var"#_fetch_with_delay##kw", NamedTuple{(:since, :params, :df), Tuple{Int64, Base.Dict{Any, Any}, Bool}}, typeof(Backtest.Exchanges._fetch_with_delay), PyCall.PyObject, String, String})
    isdefined(Backtest, Symbol("#_load_pair##kw")) && precompile(Tuple{Backtest.Data.var"#_load_pair##kw", NamedTuple{(:as_z,), Tuple{Bool}}, typeof(Backtest.Data._load_pair), Backtest.Data.ZarrInstance, String, Float64})
    isdefined(Backtest, Symbol("#_save_pair##kw")) && precompile(Tuple{Backtest.Data.var"#_save_pair##kw", NamedTuple{(:reset,), Tuple{Bool}}, typeof(Backtest.Data._save_pair), Backtest.Data.ZarrInstance, String, Float64, DataFrames.DataFrame})
    isdefined(Backtest, Symbol("#fill_missing_rows!##kw")) && precompile(Tuple{Backtest.Data.var"#fill_missing_rows!##kw", NamedTuple{(:strategy,), Tuple{Symbol}}, typeof(Backtest.Data.fill_missing_rows!), DataFrames.DataFrame, Dates.Hour})
    isdefined(Backtest, Symbol("#save_pair##kw")) && precompile(Tuple{Backtest.Data.var"#save_pair##kw", NamedTuple{(:reset,), Tuple{Bool}}, typeof(Backtest.Data.save_pair), Backtest.Data.ZarrInstance, String, String, String, DataFrames.DataFrame})
    precompile(Tuple{typeof(Backtest.Analysis.__init__)})
    precompile(Tuple{typeof(Backtest.Data.__init__)})
    precompile(Tuple{typeof(Backtest.Data._check_contiguity), Float64, Float64, Float64, Float64, Float64})
    precompile(Tuple{typeof(Backtest.Data.is_incomplete_candle), DataFrames.DataFrameRow{DataFrames.DataFrame, DataFrames.Index}, Float64})
    precompile(Tuple{typeof(Backtest.Data.is_incomplete_candle), Float64, Float64})
    precompile(Tuple{typeof(Backtest.Data.is_last_complete_candle), Float64, String})
    precompile(Tuple{typeof(Backtest.Exchanges.__init__)})
    precompile(Tuple{typeof(Backtest.Exchanges.loadmarkets!), PyCall.PyObject})
    precompile(Tuple{typeof(Backtest.Exchanges.to_df), Array{Float64, 2}})
    precompile(Tuple{typeof(Backtest.Misc.Pbar.__init__)})
    precompile(Tuple{typeof(Backtest.Misc.tfnum), Dates.Hour})
    precompile(Tuple{typeof(Backtest.Misc.timefloat), Dates.DateTime})
    precompile(Tuple{typeof(Backtest.Misc.timefloat), Dates.Millisecond})
end
