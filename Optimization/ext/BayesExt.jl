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

@doc """ Constructs a Gaussian Process model with ElasticGPE.

$(TYPEDSIGNATURES)

The function `gpmodel` constructs a Gaussian Process model using the ElasticGPE function from the BayesianOptimization.GaussianProcesses module. 
It sets the mean, kernel, logNoise, and capacity of the model. 
The function also sets priors for the mean of the model. 
The number of dimensions (`ndims`) is passed as an argument to the function.
"""
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

@doc """ Returns a MAPGPOptimizer.

$(TYPEDSIGNATURES)

The `modelopt` function returns a Maximum a Posteriori Gaussian Process Optimizer (MAPGPOptimizer) with a specified frequency of optimization (`every`) and maximum number of evaluations (`maxeval`).
"""
function modelopt(_)
    MAPGPOptimizer(; every=2, maxeval=10)
end

@doc """ Configures the acquisition function for Bayesian optimization.

$(TYPEDSIGNATURES)

The `acquisition` function configures the acquisition function for Bayesian optimization. It sets the optimization method, the number of restarts, the maximum time, and the maximum number of evaluations.
"""
function acquisition(_)
    (; method=:LD_LBFGS, restarts=2, maxtime=0.1, maxeval=1000)
end

@doc """Optimize strategy `s` using Bayesian optimization.

$(TYPEDSIGNATURES)

The `boptimize!` function optimizes a given strategy `s` using Bayesian optimization. 
It allows for customization of the Gaussian Process model, the model optimizer, and the acquisition function through the `BayesianOptimization` package. 
The function also supports specification of a random seed, the number of splits in the optimization process, the maximum number of iterations, and the maximum duration of the optimization process. 
The function initializes an optimization session, defines a backtest function and an optimization function, and finally carries out the optimization, returning the optimization session and results.

"""
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
