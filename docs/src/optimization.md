# Optimization

PingPong provides tools to optimize strategy parameters. Optimzations are managed through the `OptSession` type. Which is a structure that holds informations about the optimization parameters, configuration and previous runs.
Optimization sessions can be periodically saved, and therefore can be reloaded at a later time to explore previous results or continue the optimization from where it left off.

There are currently 3 different optimization methods: `gridsearch`, `bboptimize` `boptimize!`.
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
gridsearch(s, repeats=1, save_freq=Minute(1), resume=false)
```
Will perform an search from scratch, saving every minute.
`repeats` controls the number of times a backtest is run using the _same_ combination of parameters. When repeats > 1 we split the optimization `Context` into shorter ranges and restart the backtest on each one of these sub contexes. This allows to fuzz out scenarios of overfitting by averaging the results of different backtest "restarts".

### Black box optimization
The `BlackBoxOptim` offers multiple methods for searching, also also offers multi objective optimization. You can pass any arg supported by the upstream `bboptimze` function.

```julia
Optimization.bboptimize(s, repeats=3, MaxTime=240.0, Method=:borg_moea)
```
We exclude some optimization methods because they are slow or for some other quirks. Get the list of methods by calling `bbomethods`.
```julia
Optimization.bbomethods()
Optimization.bbomethods(true) # multi obj methods
```
`@doc bboptimize` shows some common argument you might want to pass to the optimization function like `MaxTime` or `MaxSteps`. For the full list refer to the `BlackBoxOptimi` package.

The `BayesianOptimization` package instead focus on gausiann processes and is provided as an extension of the `Optimization` package, (you need to install the packgage yourself). If you want to customize the optimization parameters you can define methods for your strategy over the functions `gpmodel`, `modelopt` and `acquisition`.
Like `bboptimize` you can pass any upstream kwargs to `boptimize!`.

## Multi threading
Parallel execution is supported for the optimizations in different capacities. For grid search we allow parallel execution between different combinations, while repetitions are done sequentially. For black box optimization instead, repetitions are done in parallel, while the optimization run is done sequentially because the improvement of parallel execution during optimization is marginal, and because `BlackBoxOptim` current multi threading support is broken.
Multi threading is only enabled if the strategy defines a global value like:
```julia
const THREADSAFE = Ref(true)
```

!!! warning "Thread safety"
    Multi threading is not safe in general, avoid any use of python objects within your strategy or you will incur into crashes. Use locks or `ConcurrentCollections` for synchronization. You are responsible for the thread safety of your strategy.

## Plotting results
After completing an optimization, the results can be plotted using the function `Plotting.plot_results`. The function accepts many arguments in order to customize which axes to plot (up to 3), how to customize coloring of plot elements (e.g. default cash column in a scatter plot go from red to green) and how to group results elements. It by default plot a scatter. Surfaces and contourf also work fine.

!!! info "Loading order of modules"
    To load the `plot_results` function first activate the `Plotting` module, then load it and then load the `Optimization` module. Alternatively, there is a convenience function in `PingPong` such that you can do `using PingPong; optplots!()`.
