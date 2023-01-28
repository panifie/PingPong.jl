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
 failed. Please report an issue in $($modl) (after checking for duplicates) or remove this directive.""" _file =
            $file _line = $line
    end
end

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    isdefined(JuBot, Symbol("##_get_zarray#11")) && precompile(
        Tuple{
            JuBot.Data.var"##_get_zarray#11",
            Type,
            Bool,
            Bool,
            typeof(JuBot.Data._get_zarray),
            JuBot.Data.ZarrInstance,
            String,
            Tuple{Int64,Int64},
        },
    )
    isdefined(JuBot, Symbol("##_save_pair#12")) && precompile(
        Tuple{
            JuBot.Data.var"##_save_pair#12",
            String,
            Type,
            Int64,
            Int64,
            Bool,
            Bool,
            typeof(JuBot.Data._save_pair),
            JuBot.Data.ZarrInstance,
            String,
            Float64,
            DataFrames.DataFrame,
        },
    )
    isdefined(JuBot, Symbol("#_fetch_one_pair##kw")) && precompile(
        Tuple{
            JuBot.Exchanges.var"#_fetch_one_pair##kw",
            NamedTuple{(:from, :to),Tuple{Float64,String}},
            typeof(JuBot.Exchanges._fetch_one_pair),
            PyCall.PyObject,
            JuBot.Data.ZarrInstance,
            String,
            String,
        },
    )
    isdefined(JuBot, Symbol("#_fetch_with_delay##kw")) && precompile(
        Tuple{
            JuBot.Exchanges.var"#_fetch_with_delay##kw",
            NamedTuple{(:since, :params, :df),Tuple{Int64,Base.Dict{Any,Any},Bool}},
            typeof(JuBot.Exchanges._fetch_with_delay),
            PyCall.PyObject,
            String,
            String,
        },
    )
    isdefined(JuBot, Symbol("#_load_pair##kw")) && precompile(
        Tuple{
            JuBot.Data.var"#_load_pair##kw",
            NamedTuple{(:as_z,),Tuple{Bool}},
            typeof(JuBot.Data._load_pair),
            JuBot.Data.ZarrInstance,
            String,
            Float64,
        },
    )
    isdefined(JuBot, Symbol("#_save_pair##kw")) && precompile(
        Tuple{
            JuBot.Data.var"#_save_pair##kw",
            NamedTuple{(:reset,),Tuple{Bool}},
            typeof(JuBot.Data._save_pair),
            JuBot.Data.ZarrInstance,
            String,
            Float64,
            DataFrames.DataFrame,
        },
    )
    isdefined(JuBot, Symbol("#fill_missing_rows!##kw")) && precompile(
        Tuple{
            JuBot.Data.var"#fill_missing_rows!##kw",
            NamedTuple{(:strategy,),Tuple{Symbol}},
            typeof(JuBot.Data.fill_missing_rows!),
            DataFrames.DataFrame,
            Dates.Hour,
        },
    )
    isdefined(JuBot, Symbol("#save_pair##kw")) && precompile(
        Tuple{
            JuBot.Data.var"#save_pair##kw",
            NamedTuple{(:reset,),Tuple{Bool}},
            typeof(JuBot.Data.save_pair),
            JuBot.Data.ZarrInstance,
            String,
            String,
            String,
            DataFrames.DataFrame,
        },
    )
    precompile(Tuple{typeof(JuBot.Analysis.__init__)})
    precompile(Tuple{typeof(JuBot.Data.__init__)})
    precompile(
        Tuple{typeof(JuBot.Data._check_contiguity),Float64,Float64,Float64,Float64,Float64}
    )
    precompile(
        Tuple{
            typeof(JuBot.Data.is_incomplete_candle),
            DataFrames.DataFrameRow{DataFrames.DataFrame,DataFrames.Index},
            Float64,
        },
    )
    precompile(Tuple{typeof(JuBot.Data.is_incomplete_candle),Float64,Float64})
    precompile(Tuple{typeof(JuBot.Data.is_last_complete_candle),Float64,String})
    precompile(Tuple{typeof(JuBot.Exchanges.__init__)})
    precompile(Tuple{typeof(JuBot.Exchanges.loadmarkets!),PyCall.PyObject})
    precompile(Tuple{typeof(JuBot.Exchanges.to_df),Array{Float64,2}})
    precompile(Tuple{typeof(JuBot.Misc.Pbar.__init__)})
    precompile(Tuple{typeof(JuBot.Misc.tfnum),Dates.Hour})
    precompile(Tuple{typeof(JuBot.Misc.timefloat),Dates.DateTime})
    precompile(Tuple{typeof(JuBot.Misc.timefloat),Dates.Millisecond})
end
