# Troubleshooting

## Precompilation fails

- A repo update might have added some dependencies. If there are problems with precompilation ensure all the packages are resolved.

```julia
include("resolve.jl")
recurse_projects() # optional ;update=true
```

- If you are not doing it already, try to load the repl passing the project as arg, e.g.:

```julia
julia --project=.
```
Avoid starting a repl and then calling `Pkg.activate(".")` when precompiling.

- Precompilation of things that depend on python (like exchange functions) can cause segfaults. Some famous suspects that can cause dangling pointers in the precompiled code are:
  - global caches, like the `tickers_cache`, since the content of global constants is serialized by precompilation, make sure that those constants are *empty* during precompilation.
  - macros like `@py` can rewrite code putting _in place_ python objects. Avoid use of those macros in functions that you want precompiled.
  
- If some package keeps skipping precompilation, it is likely that the `JULIA_NOPRECOMP` env var contains dependencies of such package.

## Python can't find modules

- If python complains about missing dependencies, while in the julia REPL, with this repository as the activated project, do this:

```julia
; find ./ -name .CondaPkg | xargs -I {} rm -r {} # Delete existing conda environments
using Python # Loads our python wrapper around CondaPkg which fixes `PYTHONPATH` env var
import Pkg; Pkg.instantiate()
```

- Alternatively force CondaPkg env resolution, from `julia --project.`

```julia
using Python.PythonCall.C.CondaPkg
CondaPkg.resolve(force=true)
```

restart the REPL.

## It is unresponsive

- If the exchange instance has been idle for quite a while the connection might have been closed. It should fail according to the ccxt exchange timeout, although more often than not it takes longer. After the inevitable timeout error the connection is re-established and subsequent functions that rely on api calls should become responsive again.

## Can't save data

- If you are using LMDB with zarr (which is default) the initial db size is 64MB. To increase it:

```julia
using Data
zi = zilmdb()
Data.mapsize!(zi, 1024) # This will set the max DB size to 1GB
Data.mapsize!!(zi, 100) # Double bang (!!) will _add_ to the previous mapsize (in this case 1.1GB)
```

Whenever the stored data reaches the mapsize, you have to increase it.

## Plotting tooltips are unaligned

Likely a bug with `WGLMakie`, use `GLMakie` instead:

```julia
using GLMakie
GLMakie.activate!()
```

