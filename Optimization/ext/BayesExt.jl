module BayesExt
using Optimization
using Optimization:
    running!,
    stopping!,
    isrunning,
    lowerupper,
    define_backtest_func,
    define_opt_func,
    ctxsteps,
    objectives,
    SimMode
using .SimMode: start!, SimMode as sm, ping!
using .SimMode.Executors: st, Instances, OptSetup, OptRun, OptScore, Context
using .SimMode.Misc.Lang: @preset, @precomp
using .SimMode.TimeTicks
using BayesianOptimization
using BayesianOptimization.GaussianProcesses
using .GaussianProcesses.Distributions
using Random
import BayesianOptimization: boptimize!

function gpmodel(_, ndims)
    model = ElasticGPE(
        ndims;
        mean=MeanConst(0.0),
        kernel=SEArd([0.0 for _ in 1:ndims], 5.0),
        logNoise=0.0,
        capacity=1000,
    )
    set_priors!(model.mean, [Normal(1, 2)])
    model
end

function modelopt(_)
    MAPGPOptimizer(; every=2, maxeval=10)
end

function acquisition(_)
    (; method=:LD_LBFGS, restarts=2, maxtime=0.1, maxeval=1000)
end

@doc "Optimize strategy `s` using bayesian optimization. For customizatoin see the `BayesianOptimization` pkg and
define custom `gpmodel`,`modelopt`,`acquisition` functions.
"
function boptimize!(
    s; seed=1, splits=1, maxiterations=1e4, maxduration=60.0, kwargs...
)
    Random.seed!(seed)
    running!()
    ctx, params, space = ping!(s, OptSetup())
    sess = OptSession(s; ctx, params, attrs=Dict(pairs((; seed, splits, space))))

    ndims = max(1, length(params))
    model = gpmodel(s, ndims)
    # Optimize the hyperparameters of the GP using maximum a posteriori (MAP) estimates every 20 steps
    modeloptimizer = modelopt(s)

    backtest_func = define_backtest_func(sess, ctxsteps(ctx, splits)...)
    obj_type, n_obj = objectives(s)
    @assert isone(n_obj) "Found $n_obj scores, expected one (check stratety `OptScore`)."
    sess.best[] = zero(eltype(obj_type))
    ismulti = n_obj > 1
    opt_func = define_opt_func(
        s; backtest_func, ismulti, obj_type, splits, isthreaded=false
    )
    res = opt = nothing
    lower, upper = lowerupper(params)
    try
        opt = BOpt(
            opt_func,
            model,
            ExpectedImprovement(),
            modeloptimizer,
            Vector{Float64}(lower),
            Vector{Float64}(upper);
            repetitions=splits,
            sense=Max,
            maxiterations,
            maxduration,
            acquisitionoptions=acquisition(s),
            kwargs...,
        )
        res = boptimize!(opt)
    catch e
        stopping!()
        rethrow(e)
        display(e)
    end
    stopping!()
    (sess, (; opt, res))
end

export boptimize!

if occursin("Optimization", get(ENV, "JULIA_PRECOMP", ""))
    @preset begin
        st.Instances.Exchanges.Python.py_start_loop()
        s = Optimization._precomp_strat(BayesExt)

        @precomp boptimize!(s, maxiterations=10)
        st.Instances.Exchanges.Python.py_stop_loop()
    end
end
end
