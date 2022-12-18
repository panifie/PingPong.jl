[![build-status](https://github.com/untoreh/Backtest.jl/actions/workflows/docs.yml/badge.svg?branch=master)](https://www.unto.re/Backtest.jl)

Currently not really a backtest framework. Mostly data.

## Install
Backtest.jl is not in the julia registry, to install do the following:

- Clone the repository:
```bash
git clone --recurse-submodules https://github.com/untoreh/Backtest.jl backtest
```
Activate the project:
```bash
cd backtest
julia --project=.
```
Download and build dependencies:
```bash
import Pkg; Pkg.instantiate()
```

## TroubleShooting
If python complains about missing dependencies, while in the julia REPL, with this repository as the activated project, do this:
```julia
; find ./ -name .CondaPkg | xargs -I {} rm -r {} # Delete existing conda environments
using Python # Loads our python wrapper around CondaPkg which fixes `PYTHONPATH` env var
import Pkg; Pkg.instantiate()
```
