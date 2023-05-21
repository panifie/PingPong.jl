[![Discord](https://img.shields.io/discord/1079307635934904370)](https://discord.gg/xDeBmSzDUr) [![build-status](https://github.com/panifie/PingPong.jl/actions/workflows/docs.yml/badge.svg?branch=master)](https://panifie.github.io/PingPong.jl/)

![Ping Pong](./docs/pingponglogo-384.png)

- :zap: Backtesting with C-like speeds!
- :bar_chart: Highly interactive and explorative plotting!
- :rocket: Trivial deployments!

All within your fingertips!

The one-of-a-kind solution for automated (crypto)trading. PingPong is unparalleled in its flexibility to adapt to different trading environments. The bot is setup to be easy to customize, and can execute any kind of strategy thanks to an approachable set of interfaces. It comes with a backtest engine that also supports trading with margin (and therefore position management). Paper mode allows to dry run your strategies before executing them in Live mode. The framework allows to achieve no code duplication between simulated and live modes.

[:book:DOCUMENTATION](https://panifie.github.io/PingPong.jl/)

[:speech_balloon:DISCORD CHAT](https://discord.gg/xDeBmSzDUr)

## A non exhaustive list of features...
- :chart_with_upwards_trend: Backtest in spot markets, or with margin in isolated mode).
- :bar_chart: Plotting for OHLCV, custom indicators, trades history, asset balance history
- :mag: Optimization (not implemented)
- :page_facing_up: Paper mode (not implemented)
- :red_circle: Live (not implemented)
- :stop_button: Telegram Bot (not implemented)
- :desktop_computer: Dashboard (not implemented)
- :satellite: Help you write data feeds to monitor exchanges or 3rd party apis.
- :arrow_down: Download data from external archives in parallel, and api wrappers for crypto apis.
- :floppy_disk: Store and load OHLCV (and arbitrary) data locally or remotely (with resampling).
- :wrench: Implement custom behaviour thanks to a fine grained type hierarchy for instruments, exchanges, orders, etc...


## Install
PingPong.jl requires at least Julia 1.9. Is not in the julia registry, to install it do the following:

- Clone the repository:
```bash
git clone --recurse-submodules https://github.com/panifie/PingPong.jl PingPong
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
ENV["JULIA_CONDAPKG_ENV"] = joinpath(dirname(Base.active_project()), ".conda")
import Pkg; Pkg.instantiate()
```

## Warning
The api is *not* stable. If you want more stability around some functionality open an issue for the function of interest such that I can add a test around it. 

