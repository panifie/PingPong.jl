# Optimization

PingPong provides tools to optimize strategy parameters. Optimzations are managed through the [`Optimization.OptSession`](@ref) type. Which is a structure that holds informations about the optimization parameters, configuration and previous runs.
Optimization sessions can be periodically saved, and therefore can be reloaded at a later time to explore previous results or continue the optimization from where it left off.

There are currently 3 different optimization methods: [`Optimization.gridsearch`](@ref), [`Optimization.bboptimize`](@ref), `boptimize!`(when using `BayesianOptimization`).
Configuration is done by defining three `ping!` functions.

- `ping!(::S, ::OptSetup)`: returns a named tuples with:
   - `ctx`: a `Executors.Context` which is the period of time used for backtesting
   - `params`: a named tuple of all the parameters to be optimizied. Values should be in the form of iterables.
   - `space`: only required for `bboptimize`, a named tuple where
     - `kind`: is the type of space (from `BlackBoxOptim` package)
     - `precision`: If the space is `:MixedPrecisionRectSearchSpace` it is a vector where each element is the number of decimals to consider in parameters of type float.
- `ping!(::S, ::OptRun)`: called before a single backtest is run. Receives one combination of the parameters. Should apply the parameters to the strategy. No return values expected.
- `ping!(::S, ::OptScore)::Vector`: for `bboptimize` and `boptimize!` it is the objective score that advances the optimization. In grid search it can be used to store additional metrics in the results dataframe. Within the `Stats` package there are metrics like `sharpe`` or `sortino` commonly used as optimization objectives.

### Grid search
This is the recommended approach, useful if the strategy has a small set of parameters (<5).
```julia
using Optimization
gridsearch(s, splits=1, save_freq=Minute(1), resume=false)
```
Will perform an search from scratch, saving every minute.
`splits` controls the number of times a backtest is run using the _same_ combination of parameters. When splits > 1 we split the optimization `Context` into shorter ranges and restart the backtest on each one of these sub contexes. This allows to fuzz out scenarios of overfitting by averaging the results of different backtest "restarts".

### Black box optimization
The `BlackBoxOptim` offers multiple methods for searching, also also offers multi objective optimization. You can pass any arg supported by the upstream `bboptimze` function.

```julia
Optimization.bboptimize(s, splits=3, MaxTime=240.0, Method=:borg_moea)
```
We exclude some optimization methods because they are slow or for some other quirks. Get the list of methods by calling `bbomethods`.
```julia
Optimization.bbomethods()
Optimization.bbomethods(true) # multi obj methods
```
`@doc bboptimize` shows some common argument you might want to pass to the optimization function like `MaxTime` or `MaxSteps`. For the full list refer to the `BlackBoxOptimi` package.

The `BayesianOptimization` package instead focus on gausiann processes and is provided as an extension of the `Optimization` package, (you need to install the packgage yourself). If you want to customize the optimization parameters you can define methods for your strategy over the functions `gpmodel`, `modelopt` and `acquisition`.
Like `bboptimize` you can pass any upstream kwargs to `boptimize!`.

## Multi-threading
Parallel execution is supported for optimizations, though the extent and approach vary depending on the optimization method used.

### Grid Search
In grid search optimizations, parallel execution is permitted across different parameter combinations, enhancing efficiency. However, repetitions of the optimization process are executed sequentially to maintain result consistency.

### Black Box Optimization
For black box optimization, the scenario is reversed: repetitions are performed in parallel to expedite the overall process, while the individual optimization runs are sequential. This approach is due to the limited benefits of parallelizing these runs and the current limitations in the `BlackBoxOptim` library's multi-threading support.

To enable multi-threading, your strategy must declare a global thread-safe flag as follows:
```
julia
const THREADSAFE = Ref(true)
```

!!! warning "Thread Safety Caution"
    Multi-threading can introduce safety issues, particularly with Python objects. To prevent crashes, avoid using Python objects within your strategy and utilize synchronization mechanisms like locks or `ConcurrentCollections`. Ensuring thread safety is your responsibility.

## Plotting Results
Visualizing the outcomes of an optimization can be accomplished with the `Plotting.plot_results` function. This function is versatile, offering customization options for axes selection (supports up to three axes), color gradients (e.g., depicting cash flow from red to green in a scatter plot), and grouping of result elements. The default visualization is a scatter plot, but surface and contour plots are also supported.

!!! info "Package Loading Order"
    The `plot_results` function is part of the `Plotting` package, which acts as an extension. To use it, perform the following steps:
    ```
    julia
    # Restart the REPL if PingPong was previously imported.
    using Pkg: Pkg
    Pkg.activate("PingPongInteractive")
    using PingPongInteractive
    # Now you can call Plotting.plot_results(...)
    ```
    Alternatively, activate and load the `Plotting` package first, followed by the `Optimization` package. The `PingPong` framework provides convenience functions to streamline this process:
    ```
    julia
    using PingPong
    plots!() # This loads the Plotting package.
    using Optimization
    ```