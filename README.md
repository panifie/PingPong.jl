[![build-status](https://github.com/untoreh/JuBot.jl/actions/workflows/docs.yml/badge.svg?branch=master)](https://www.unto.re/JuBot.jl)

Currently not really a backtest framework. Mostly data.

## Install
JuBot.jl is not in the julia registry, to install do the following:

- Clone the repository:
```bash
git clone --recurse-submodules https://github.com/untoreh/JuBot.jl jubot
```
- Activate the project:
```bash
cd jubot
git submodule init
git submodule update
julia --project=.
```
- Download and build dependencies:
```bash
import Pkg; Pkg.instantiate()
```

## Troubleshooting
If python complains about missing dependencies, while in the julia REPL, with this repository as the activated project, do this:
```julia
; find ./ -name .CondaPkg | xargs -I {} rm -r {} # Delete existing conda environments
using Python # Loads our python wrapper around CondaPkg which fixes `PYTHONPATH` env var
import Pkg; Pkg.instantiate()
```

## Contributing
The api is *not* stable. If you want more stability around some functionality open an issue for the function of interest such that I can add a test around it. 
