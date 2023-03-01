[![Discord](https://img.shields.io/discord/1079307635934904370)](https://discord.gg/VURFt4wQ)[![build-status](https://github.com/untoreh/PingPong.jl/actions/workflows/docs.yml/badge.svg?branch=master)](https://www.unto.re/PingPong.jl)

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

## Contributing
The api is *not* stable. If you want more stability around some functionality open an issue for the function of interest such that I can add a test around it. 
