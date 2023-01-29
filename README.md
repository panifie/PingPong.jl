[![build-status](https://github.com/untoreh/PingPong.jl/actions/workflows/docs.yml/badge.svg?branch=master)](https://www.unto.re/PingPong.jl)

**Supported julia version: 1.9**

Currently not really a backtest framework. Mostly data.

## Install
PingPong.jl is not in the julia registry, to install do the following:

- Clone the repository:
```bash
git clone --recurse-submodules https://github.com/untoreh/PingPong.jl PingPong
```
- Activate the project:
```bash
cd PingPong
git submodule init
git submodule update
julia --project=.
```
- Download and build dependencies:
```bash
# use centralized condapkg env
ENV["CONDA_PKG_ENV"] = joinpath(dirname(Base.active_project()), ".CondaPkg")
import Pkg; Pkg.instantiate()
```

## Troubleshooting

- A repo update might have added some dependencies. If there are problems with precompilation ensure all the packages are resolved.

```julia
include("resolve.jl")
recurse_projects() # optional ;update=true
```

- If python complains about missing dependencies, while in the julia REPL, with this repository as the activated project, do this:
```julia
; find ./ -name .CondaPkg | xargs -I {} rm -r {} # Delete existing conda environments
using Python # Loads our python wrapper around CondaPkg which fixes `PYTHONPATH` env var
import Pkg; Pkg.instantiate()
```

## Contributing
The api is *not* stable. If you want more stability around some functionality open an issue for the function of interest such that I can add a test around it. 
