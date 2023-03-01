# Troubleshooting

## Precompilation fails
- A repo update might have added some dependencies. If there are problems with precompilation ensure all the packages are resolved.

```julia
include("resolve.jl")
recurse_projects() # optional ;update=true
```

## Python can't find modules
- If python complains about missing dependencies, while in the julia REPL, with this repository as the activated project, do this:
```julia
; find ./ -name .CondaPkg | xargs -I {} rm -r {} # Delete existing conda environments
using Python # Loads our python wrapper around CondaPkg which fixes `PYTHONPATH` env var
import Pkg; Pkg.instantiate()
```

## It is unresponsive
- If the exchange instance has been idle for quite a while the connection might have been closed. It should fail according to the ccxt exchange timeout, although more often than not it takes longer. After the inevitable timeout error the connection is re-established and subsequent functions that rely on api calls should become responsive again.
