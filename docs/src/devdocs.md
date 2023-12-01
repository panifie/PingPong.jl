## PingPongDev Documentation

The `PingPongDev` package assists developers by providing helper functions for working with PingPong and for conducting tests.

### Precompilation Control

To skip precompilation for selected modules, set the `JULIA_NOPRECOMP` environment variable:

```julia
ENV["JULIA_NOPRECOMP"] = (:PingPong, :Scrapers, :Engine, :Watchers, :Plotting, :Stats)
```

Alternatively, you can manage environment variables with `direnv` (refer to the `.envrc` in the repository). To disable precompilation entirely for certain packages, use `JULIA_NOPRECOMP=all`. This is recommended only when altering low-level components of the module stack. Remember to clear the compilation cache when changing precompilation settings:

```julia
include("resolve.jl")
purge_compilecache() # Pass a package name as an argument to clear its specific cache.
```

The `Exchanges` and `Fetch` packages contain a `compile.jl` file to generate precompile statements using [CompileBot.jl](https://github.com/aminya/CompileBot.jl). This is particularly useful for precompilation tasks that involve numerous web requests. However, this method is not currently used as it does not compile as many methods as `PrecompileTools`.

!!! warning "Custom Precompilation"
    For custom method precompilation, enclose your code with `py_start_loop` and `py_stop_loop` from the Python package to prevent Pkg from stalling due to lingering threads.
    ```julia
    using PrecompileTools
    Python.py_stop_loop() # Stop the Python loop if it's running
    Python.py_start_loop()
    @precompile_workload $(myworkload...)
    Python.py_stop_loop()
    ```

### Method Invalidation Strategy

The order of `using ...` statements when loading modules can influence method invalidation. To minimize invalidation, arrange the module imports starting with the ones most likely to cause invalidations to the ones least likely. For instance, placing `using Python` at the beginning can expedite loading times:

```julia
# Load modules that heavily trigger invalidations first
using Python
using Ccxt
# Load less impactful modules later
using Timeticks
using Lang
```

Modules known for heavy invalidations:

- Python
- Ccxt (initiates the Python async loop)
- Data (relies on Zarr and DataFrames)
- Plots (depends on Makie)

To reduce invalidations, include external modules in only one local package and then use that package as a dependency in other local packages. For instance, if `DataFrames` is a dependency of the local package `Data`, and you want to use `DataFrames` in the `Stats` package, do not add `DataFrames` to `Stats` dependencies. Instead, use `Data` and import `DataFrames` from there:

```julia
module Stats

using Data.DataFrames

# ...
end
```

### Handling Segfaults

In rare cases involving complex multi-threaded scenarios, disable and re-enable the garbage collector (GC) around the loading of PingPong to avoid segmentation faults:

```julia
GC.enable(false)
using PingPong
s = st.strategy()
GC.enable(true)
GC.gc()
```

Refer to https://github.com/cjdoris/PythonCall.jl/issues/201 for more details.

### Dependency Management

When adding dependencies, ensure that a dependency is only included in one subpackage. If you need the same dependency in another subpackage, add the first subpackage as the dependency, not the external module.

The order of `using` or `import` statements within packages is crucial. Always import
```