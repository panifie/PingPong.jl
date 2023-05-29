module BayesExt
using SimMode: backtest!, SimMode as sm
using BayesianOptimization
import BayesianOptimization: boptimize!
using BayesianOptimization.GaussianProcesses
using Distributions
using Random

function gpmodel(::Strategy, ndims)
    model = ElasticGPE(
        ndims;
        mean=MeanConst(0.0),
        kernel=SEArd([0.0, 0.0], 5.0),
        logNoise=0.0,
        capacity=1000,
    )
    set_priors!(model.mean, [Normal(1, 2)])
    model
end

function modelopt(::Strategy)
    MAPGPOptimizer(; every=2, maxeval=10)
end

function acquisition(::Strategy)
    (; method=:LD_LBFGS, restarts=2, maxtime=0.1, maxeval=1000)
end

@doc "Optimize strategy `s` using bayesian optimization. For customizatoin see the `BayesianOptimization` pkg and
define custom `gpmodel`,`modelopt`,`acquisition` functions.
"
function boptimize!(
    s::Strategy; seed=1, repetitions=1, maxiterations=1e4, maxduration=60.0, kwargs...
)
    Random.seed!(seed)
    ctx, space = ping!(s, OptSetup())
    sess = OptSession(s, ctx, nothing)

    ndims = max(1, length(space[2]))
    @assert ndims == length(space[3]) "lower and upper bounds dimension mismatch"
    model = gpmodel(s, ndims)
    # Optimize the hyperparameters of the GP using maximum a posteriori (MAP) estimates every 20 steps
    modeloptimizer = modelopt(s)

    function optrun(params)
        s = similar(s)
        ctx = similar(ctx)
        ping!(s, params, OptRun())
        backtest!(s, ctx)

        obj = ping!(s, OptScore())
        cash = value(st.current_total(s))
        trades = st.trades_count(s)
        push!(
            sess.results,
            (; obj, cash, trades, (Symbol("x$n") => p for (n, p) in enumerate(params))...),
        )
        obj
    end
    res = nothing
    try
        opt = BOpt(
            optrun,
            model,
            ExpectedImprovement(),
            modeloptimizer,
            space[2], # lowerbounds
            space[3]; # upperbounds
            repetitions,
            maxiterations,
            maxduration,
            acquisitionoptions=acquisition(s),
            kwargs...,
        )
        res = boptimize!(opt)
    catch e
        rethrow(e)
        display(e)
    end
    (res, sess)
end

export boptimize!
end
