# Troubleshooting

## Precompilation Issues

- **Dependency Conflicts:** After updating the repository, new dependencies may cause precompilation to fail. Ensure all packages are fully resolved by running:

```julia
include("resolve.jl")
recurse_projects() # Optionally set update=true
```

- **Starting the REPL:** Rather than starting a REPL and then activating the project, launch Julia directly with the project as an argument to avoid precompilation issues:

```julia
julia --project=./PingPong
```

- **Python-Dependent Precompilation:** Precompiling code that relies on Python, such as exchange functions, may lead to segmentation faults. To prevent this:
  - Clear global caches, like `tickers_cache`, before precompilation. Ensure global constants are empty, as their contents are serialized during precompilation.
  - Avoid using macros that directly insert Python objects, such as `@py`, in precompilable functions.
  
- **Persistent Precompilation Skipping:** If a package consistently skips precompilation, check if `JULIA_NOPRECOMP` environment variable includes dependencies of the package.

## Python Module Discovery

- **Missing Python Dependencies:** If Python reports missing modules, execute the following in the Julia REPL with the current repository activated:

```julia
; find ./ -name .CondaPkg | xargs -I {} rm -r {} # Removes existing Conda environments
using Python # Activates our Python wrapper with CondaPkg environment variable fixes
import Pkg; Pkg.instantiate()
```

- **Force CondaPkg Environment Resolution:** In the case of persistent issues, force resolution of the CondaPkg environment by running:

```julia
using Python.PythonCall.C.CondaPkg
CondaPkg.resolve(force=true)
```

Then, restart the REPL.

## Unresponsive Exchange Instance

- **Idle Connection Closure:** If an exchange instance remains idle for an extended period, the connection may close. It should time out according to the `ccxt` exchange timeout. Following a timeout error, the connection will re-establish, and API-dependent functions will resume normal operation.

## Data Saving Issues

- **LMDB Size Limitations:** When using LMDB with Zarr, the initial database size is set to 64MB by default. To increase the maximum size:

```julia
using Data
zi = zilmdb()
Data.mapsize!(zi, 1024) # Sets the DB size to 1GB
Data.mapsize!!(zi, 100) # Adds 100MB to the current mapsize (resulting in 1.1GB total)
```

Increase the mapsize before reaching the limit to continue saving data.

## Misaligned Plotting Tooltips

- **Rendering Bugs:** If you encounter misaligned tooltips with `WGLMakie`, switch to `GLMakie` to resolve rendering issues:

```julia
using GLMakie
GLMakie.activate!()
```