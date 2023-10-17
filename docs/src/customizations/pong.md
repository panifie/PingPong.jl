# Adding pong functions

When introducing new `pong!` functions follow these steps:

- Add the new trait to the `Executors` module, look in the `Executors/src/executors.jl` file. Export it.
- Implement the relative functions, add them to `{SimMode,PaperMode,LiveMode}/src/pong.jl`. You can just dispatch the same function to paper and live mode if there is no difference, by using `RTStrategy` and place the definition in `PaperMode/src/pong.jl`.
- In `PingPong/src/pingpong.jl` modify the `@strategyeng!` macro (or the `@contractsenv!` macro if the function deals with derivatives) and import the new trait (e.g. `using .pp.Engine.Executors: MyNewTrait`)

Remember to follow the arguments order convention for the strategy signature:

```julia
pong!(s::Strategy, [args...], ::MyNewTrade; kwargs...)
```
