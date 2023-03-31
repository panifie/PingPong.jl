[![Discord](https://img.shields.io/discord/1079307635934904370)](https://discord.gg/xDeBmSzDUr) [![build-status](https://github.com/untoreh/PingPong.jl/actions/workflows/docs.yml/badge.svg?branch=master)](https://untoreh.github.io/PingPong.jl/)

![Ping Pong](./docs/pingponglogo-384.png)

**Supported julia version: 1.9**

## What can it do?
- Help you write data feeds to monitor exchanges or 3rd party apis.
- Download data from external archives in parallel, and api wrappers for crypto apis.
- Store and load OHLCV (and arbitrary) data locally or remotely (with resampling).
- Organize your strategy using a predefined type hierarchy for instruments, exchanges, orders.
- Backtesting (to be improved)
- Optimization (not implemented)
- Plotting (to be improved)
- Dry run (not implemented)
- Live (not implemented)
- Telegram Bot (not implemented)
- Dashboard (not implemented)


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

### Adding dependencies
Only add a dependency to one of the subpackages, when using the same dependency from another subpackage, add the subpackage that already has that dependency instead of the dependency itself.
