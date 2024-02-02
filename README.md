[![Discord](https://img.shields.io/discord/1079307635934904370)](https://discord.gg/xDeBmSzDUr) [![build-status-docs](https://github.com/panifie/PingPong.jl/actions/workflows/docs.yml/badge.svg?branch=master)](https://panifie.github.io/PingPong.jl/) [![build-status-docker](https://github.com/panifie/PingPong.jl/actions/workflows/build.yml/badge.svg?branch=master)](https://github.com/panifie/PingPong.jl/actions/workflows/build.yml) [![tests](https://github.com/panifie/PingPong.jl/actions/workflows/tests.yml/badge.svg?branch=master)](https://github.com/panifie/PingPong.jl/actions/workflows/tests.yml)

![Ping Pong](./docs/pingponglogo-384.png)

<!-- PRESENTATION BEGIN -->

> _PingPong, advanced solutions for demanding practitioners_

PingPong is a framework designed to help you build your own trading bot. While it is primarily built around the [CCXT](https://github.com/ccxt/ccxt) API, it can be extended to work with any custom exchange, albeit with some effort.

### One Language to Rule Them All
Many trading bots are implemented in Python, which can lead to slow or hard-to-customize vectorized backtesters. By writing trading strategies in Julia, PingPong can perform efficiently during both backtesting and live execution. Other bots implement a faster backtester in another language (Cython, Numba, Rust) but still pay the price for calling code from strategies written in Python, or require the user to implement the strategy itself in a less ergonomic language.

PingPong, being fully written in Julia, does not incur these trade-offs and can offer performant execution in both simulations and live trading. Moreover, sharing the same language means that anyone who manages trading strategies in Julia can also contribute to making the PingPong backtester (and the rest) better and faster for every other user. In other words, a contribution to the PingPong codebase is a worthwhile investment more so than over other non-Julia trading frameworks.

### Customizations
Julia's dispatch mechanism makes it easy to customize any part of the bot without feeling like you are monkey patching code. It allows you to easily implement ad-hoc behavior to solve exchange API inconsistencies (despite CCXT's best efforts at unification). You don't have to wait for upstream to fix some annoying exchange issue, you can fix most things by dispatching a function instead of having to maintain a fork with a patchset. Ad-hoc customizations are non-intrusive.

### Margin and Leverage
Most open-source trading frameworks don't have a fully thought-out system for handling margined positions. PingPong employs a type hierarchy that can handle isolated and cross margin trading, with hedged or unhedged positions. (However, only isolated unhedged positions management is currently implemented, PRs welcome).

### Large Datasets
Strategies can take a lot of data but not everything can fit into memory. PingPong addresses this issue head-on by relying on [Zarr.jl](https://github.com/JuliaIO/Zarr.jl) for persistence of OHLCV timeseries (and other) with the ability to access data progressively chunk by chunk. It also allows you to _save_ data chunk by chunk.

### Data Consistency
When dealing with timeseries we want to make sure data is _sane_. More than other frameworks, PingPong goes the extra mile to ensure that OHLCV data does not have missing entries, requiring data to be contiguous. During IO, we check the dates index to ensure data is always properly appended or prepended to existing ones.

### Data Feeds
Many frameworks are eager to provide data that you can use to develop your strategies with backtesting in mind, but leave you hanging when it comes to pipeline fresh data into live trading. PingPong provides a standard interface that makes it easier to build jobs that fetch, process and store data feeds to use in real-time.

### Lookahead Bias
Dealing with periods of time is crucial for any trading strategy, yet many trading frameworks gloss over this not so small detail causing repeated lookahead bias bugs. PingPong implements a full-featured library to handle parsing and conversions of both dates and timeframes. It has convenient macros to handle date periods and timeframes within the REPL and provides indexing by date and range of dates for dataframes.

### Multiplicity
Handling a large number of strategies can be cumbersome and brittle. PingPong doesn't step on your toes when you are trying to piece everything together, because there are no requirements for a runtime environment, there is no overly complicated setup, starting and stopping strategies is as easy as calling `start!` and `stop!` on the strategy object. That's it. You can construct higher-level cross-currency or cross-exchange systems by just instantiating multiple strategies.

### Peculiar Backtesting
Other frameworks build the backtester like an event-driven "simulated" exchange such that they can mirror as precise as possible real-world exchanges. In PingPong instead, the backtester is functionally a loop, with execution implemented _from scratch_. This makes the backtester:
- Simpler to debug (it is _self-contained_)
- Faster (it is _synchronous_)
- Friendlier to parameter optimization (it is _standalone_ and easy to parallelize)

### By-Simulation
The fine-grained ability to simulate orders and trades allows us to run the simulation *even during live trading*. This means that we can either tune our simulation against our chosen live trading exchange, or be alerted about exchange misbehavior when our simulation diverges from exchange execution. Achieving this with an event-driven backtester ends up being either very hard, a brittle mess or simply impossible. This is a unique feature of PingPong that no other framework provides and we called it _by-simulation_[^1].

### Low Strategy Code Duplication
In every execution mode, there is always a view of the strategy state which is local first, there is full access to orders, trades history, balances. What differs between the execution modes is not what but how all our internal data structures are populated, which is abstracted away from the user. From the user perspective, strategy code works the same during backtesting, paper and live trading. Yet the user can still choose to branch execution on different modes, for example, to pre-fill some data during simulations, the strategy is of course always self-aware of what mode it is running in.

### Thin Abstractions
Other frameworks achieve low code duplication by completely abstracting away order management and instead provide a _signal_ interface. PingPong abstractions are thin, from the strategy, you are sending orders directly yourself, there is no man in the middle, you decide how, what, when to enter or exit trades. If you want a higher level of abstractions like signals and risk management, those can be implemented as modules that the strategy depends on, PRs welcome.

## Pingpong also...
- Can plot OHLCV data, custom indicators, trades history, asset balance history
- Can perform parameter optimization using grid search, evolution and Bayesian opt algorithms. Has restore/resume capability and plotting of the optimization space.
- In Paper mode, trades are simulated using the real order book and exchange trades history
- Has a Telegram bot to control strategies
- Can download data from external archives in parallel, and has API wrappers for crypto APIs.
- Can still easily call into python (with async support!) if you wish

## Comparison
Here's a comparison of features with other popular trading frameworks:

> ⚠️ This table might be imprecise or outdated (please file an [issue](https://github.com/panifie/PingPong.jl/issues) for improvements)

| _Feature_                     | *PingPong*   | [*Freqtrade*](https://github.com/freqtrade/freqtrade) | [*Hummingbot*](https://github.com/hummingbot/hummingbot) | [*OctoBot*](https://github.com/Drakkar-Software/OctoBot) | [*Jesse*](https://github.com/jesse-ai/jesse) | [*Nautilus*](https://github.com/nautechsystems/nautilus_trader) | [*Backtrader*](https://github.com/mementum/backtrader) |
|-------------------------------|:------------:|:-----------------------------------------------------:|:--------------------------------------------------------:|:--------------------------------------------------------:|:--------------------------------------------:|:---------------------------------------------------------------:|:------------------------------------------------------:|
| 🔴 Paper/Live execution       | ✔️            | ✔️                                                     | ✔️                                                        | ✔️                                                        | 〰️                                           | 〰️                                                              | 〰️                                                     |
| 🎛 Remote control              | ✔️            | ✔️                                                     | ✔️                                                        | ✔️                                                        | ❌                                           | ❌                                                              | ❌                                                     |
| 💾 Data Management            | ✔️            | ✔️                                                     | ❌                                                       | ❌                                                       | ❌                                           | ❌                                                              | ✔️                                                      |
| ⚡ Fast & flexible backtester | ✔️            | ❌                                                    | ❌                                                       | ❌                                                       | ❌                                           | ✔️                                                               | ❌                                                     |
| 📈 DEX support                | ❌ (planned) | ❌                                                    | ✔️                                                        | ❌                                                       | ✔️                                            | ❌                                                              | ❌                                                     |
| 💰 Margin/Leverage            | ✔️            | ❌                                                    | ❌                                                       | ✔️                                                        | ✔️                                            | ✔️                                                               | ❌                                                     |
| 🔍 Optimization               | ✔️            | ✔️                                                     | ❌                                                       | ✔️                                                        | ✔️                                            | ❌                                                              | ❌                                                     |
| 📊 Plotting                   | ✔️            | ✔️                                                     | ❌                                                       | ✔️                                                        | ✔️                                            | ❌                                                              | 〰️                                                     |
| 🖥 Dashboard                   | ❌           | ✔️                                                     | ✔️                                                        | ✔️                                                        | ❌                                           | ❌                                                              | ❌                                                     |
| 📡 Live feeds                 | ✔️            | ❌                                                    | ❌                                                       | ❌                                                       | ❌                                           | ✔️                                                               | ✔️                                                      |
| 🛡 Bias hardened               | ✔️            | ✔️                                                     | ❌                                                       | ❌                                                       | ❌                                           | ❌                                                              | ❌                                                     |
| 🔧 Customizable               | ✔️            | ❌                                                    | ✔️                                                        | ❌                                                       | ❌                                           | ✔️                                                               | ❌                                                     |
| 🪛 Composable                 | ✔️            | ❌                                                    | ❌                                                       | ❌                                                       | ❌                                           | ✔️                                                               | ✔️                                                      |
| 🔁 Low code duplication       | ✔️            | ✔️                                                     | ❌                                                       | ✔️                                                        | ❌                                           | ✔️                                                               | ❌                                                     |
| ⚓ By-Simulation              | ✔️            | ❌                                                    | ❌                                                       | ❌                                                       | ❌                                           | ❌                                                              | ❌                                                     |

<!-- PRESENTATION END -->

## Install
### With docker
For developing strategies:
``` bash
# Sysimage build (the largest number of methods precompiled) plus interactive modules (plotting and optimization)
docker pull docker.io/panifie/pingpong-sysimage-interactive

```
For running live strategies
``` bash
# Sysimage build with only the core components, better for live deployments
docker pull docker.io/panifie/pingpong-sysimage
```

For developing pingpong

``` bash
# Precomp build. Slower loading times, smaller image
docker pull docker.io/panifie/pingpong-precomp-interactive
# Precomp build without interactive modules
docker pull docker.io/panifie/pingpong-precomp
```

### From sources
PingPong.jl requires at least Julia 1.9. Is not in the julia registry, to install it do the following:

- Clone the repository:
```bash
git clone --recurse-submodules https://github.com/panifie/PingPong.jl pingpong
```
- Activate the project:
```bash
cd pingpong
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

Read the :book: documentation ([link](https://panifie.github.io/PingPong.jl/)) to learn how to get started with the bot.

For questions and direct support you can join the :speech_balloon: discord chat ([link](https://discord.gg/xDeBmSzDUr))

[PROJECT STATUS](https://github.com/panifie/PingPong.jl/issues/28)

[^1]: Not to be confused with bisimulation :)
