using Backtest.Misc: setopt!
using StatsBase: corspearman, corkendall, corkendall!
using StatsModels: lag, lead
using EffectSizes: effectsize, CohenD, HedgeG, GlassΔ
using CausalityTools: transferentropy, RectangularBinning
import CausalityTools
# import StatsBase: corspearman

@inline _x_view(x, n_lead) = @view(x[begin:end-n_lead])
@inline _y_view(y, n_lead, default=NaN) = @view(lead(y, n_lead; default)[begin:end-n_lead])

macro _wrap_df_fun(name)
    name = esc(name)
    quote
        $name(x, data::AbstractDataFrame; col=:close, kwargs...) = $name(x, getproperty(data, col); kwargs...)
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
    CohenD(_x_view(x, n_lead), _y_view(y, n_lead, default), quantile=0.95) |> effectsize
end

function hedge(x::AbstractArray, y::AbstractArray; n_lead=1, default=NaN)
    @assert n_lead > 0
    HedgeG(_x_view(x, n_lead), _y_view(y, n_lead, default), quantile=0.95) |> effectsize
end

function glass(x::AbstractArray, y::AbstractArray; n_lead=1, default=NaN)
    @assert n_lead > 0
    GlassΔ(_x_view(x, n_lead), _y_view(y, n_lead, default), quantile=0.95) |> effectsize
end

function qcorr(x::AbstractArray, y::AbstractArray, n_lead=1, default=NaN)
    x = _x_view(x, n_lead)
    y = _y_view(y, n_lead, default)
    mxy = maximum(x ./ y)
    myx = maximum(y ./ x)
    (mxy + myx - 2) / ((mxy * myx) - 1)
end

setopt!("tentr",
        (;est=CausalityTools.SymbolicPermutation(; τ=100, lt=CausalityTools.Entropies.isless_rand),
            # CausalityTools.KozachenkoLeonenko(10, 2),
            # CausalityTools.TransferOperator(RectangularBinning(2)),
            # VisitationFrequency(RectangularBinning(2)),
         base=2,
         q=1.))

function tentr(x::AbstractArray, y::AbstractArray, args...)
    opt = options["tentr"]
    transferentropy(x, selectdim(y, 1, :), opt.est;
                    base=opt.base,
                    q=opt.q)
end

macro _wrap_funcs()
    quote
        for f in [:corsp, :corke, :cohen, :hedge, :glass, :qcorr, :tentr]
            @_wrap_df_fun f
        end
    end
end

_wrap_funcs() = @_wrap_funcs()
