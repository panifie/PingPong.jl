module CorrExt
using StrategyStats
using .StrategyMt.Misc: config
using StatsBase: corspearman, corkendall, corkendall!, mean
using MetricsModels: lag, lead
using EffectSizes: effectsize, CohenD, HedgeG, GlassΔ
using CausalityTools: CausalityTools
const ct = CausalityTools
const di = ct.SMeasure.Distances

@inline _x_view(x, n_lead) = @view(x[begin:(end - n_lead)])
@inline function _y_view(y, n_lead, default=NaN)
    @view(lead(y, n_lead; default)[begin:(end - n_lead)])
end

macro _wrap_df_fun(name)
    name = esc(name)
    quote
        function $name(x, data::AbstractDataFrame; col=:close, kwargs...)
            $name(x, getproperty(data, col); kwargs...)
        end
    end
end

@doc "Compute spearman correlation between `x` and `y`, where `y` is shifted forward (lead)."
function corsp(x::AbstractArray, y::AbstractArray; n_lead=1, default=NaN)
    @assert n_lead > 0
    corspearman(_x_view(x, n_lead), _y_view(y, n_lead, default))
end

function corke(x::AbstractArray, y::AbstractArray; n_lead=1, default=NaN)
    @assert n_lead > 0
    corkendall(_x_view(x, n_lead), _y_view(y, n_lead, default))
end

function cohen(x::AbstractArray, y::AbstractArray; n_lead=1, default=NaN)
    @assert n_lead > 0
    effectsize(CohenD(_x_view(x, n_lead), _y_view(y, n_lead, default); quantile=0.95))
end

function hedge(x::AbstractArray, y::AbstractArray; n_lead=1, default=NaN)
    @assert n_lead > 0
    effectsize(HedgeG(_x_view(x, n_lead), _y_view(y, n_lead, default); quantile=0.95))
end

function glass(x::AbstractArray, y::AbstractArray; n_lead=1, default=NaN)
    @assert n_lead > 0
    effectsize(GlassΔ(_x_view(x, n_lead), _y_view(y, n_lead, default); quantile=0.95))
end

function qcorr(x::AbstractArray, y::AbstractArray, n_lead=1, default=NaN)
    x = _x_view(x, n_lead)
    y = _y_view(y, n_lead, default)
    mxy = maximum(x ./ y)
    myx = maximum(y ./ x)
    (mxy + myx - 2) / ((mxy * myx) - 1)
end

const est = Dict()
function map_estimators!()
    est[:vf] = ct.VisitationFrequency(ct.RectangularBinning(2))
    est[:sp] = ct.SymbolicPermutation()
    est[:to] = ct.TransferOperator(ct.RectangularBinning(2))
    est[:kl] = ct.KozachenkoLeonenko(10, 2)
    est[:hb] = ct.Hilbert(est[:vf])
end
map_estimators!()

# @show CausalityTools.SymbolicWeightedPermutation(;m=3)
config.attrs[:ct] = Dict(
    :tentr => (; est=est[:vf], base=2, q=1.0),
    :muten => (; est=est[:vf]),
    :predas => (; est=est[:to], ηs=2),
    :pai => (; d=2, τ=1, w=2),
    :cross => (; d=1, τ=1),
    :smeas => (; k=2),
    :joindd => (; dm=di.SqEuclidean(), B=2, D=2, τ=1),
)

function tentr(x::AbstractArray, y::AbstractArray, args...)
    opt = config.attrs[:ct][:tentr]
    ct.transferentropy(x, y, opt.est; base=opt.base, q=opt.q)
end

function muten(x::AbstractArray, y::AbstractArray, args...)
    opt = config.attrs[:ct][:muten]
    ct.mutualinfo(x, y, opt.est;)
end

function predas(x::AbstractArray, y::AbstractArray, args...)
    opt = config.attrs[:ct][:predas]
    ct.predictive_asymmetry(y, x, opt.est, opt.ηs)
end

function cross(x::AbstractArray, y::AbstractArray, n_lead=1, default=NaN)
    opt = config.attrs[:ct][:cross]
    ct.CrossMappings.pai(x, y, opt.d, opt.τ)
end

function pai(x::AbstractArray, y::AbstractArray, args...)
    opt = config.attrs[:ct][:pai]
    mean(ct.CrossMappings.pai(x, y, opt.d, opt.τ, :segment))
end

function smeas(x::AbstractArray, y::AbstractArray, n_lead=1, default=NaN)
    opt = config.attrs[:ct][:smeas]
    # FIXME: providing k as kwarg, has wrong method signature and doesn't dispatch
    ct.s_measure(_x_view(x, n_lead), _y_view(y, n_lead, default); metric=di.CosineDist())
end

# NOTE: this is heavy
function joindd(x::AbstractArray, y::AbstractArray, args...)
    opt = config.attrs[:ct][:joindd]
    mean(ct.jdd(x, y; distance_metric=opt.dm, B=opt.B, D=opt.D, τ=opt.τ))
end

macro _wrap_funcs()
    quote
        for f in [
            :corsp,
            :corke,
            :cohen,
            :hedge,
            :glass,
            :qcorr,
            :tentr,
            :muten,
            :predas,
            :cross,
            :pai,
            :smeas,
            :joindd,
        ]
            @_wrap_df_fun f
        end
    end
end

_wrap_funcs() = @_wrap_funcs()

end
