# Adding pong! Functions

To introduce new `pong!` functions, adhere to the following procedure:

1. **Traits Addition**: Go to the `Executors` module, specifically the `Executors/src/executors.jl` file, and add your new trait. Ensure that you export the trait.

2. **Function Implementation**: Define the necessary functions in the `{SimMode,PaperMode,LiveMode}/src/pong.jl` files. If the behavior for paper and live mode is identical, use `RTStrategy` as a dispatch type and place the shared function definition in `PaperMode/src/pong.jl`.

3. **Macro Modification**: In the `PingPong/src/pingpong.jl` file, modify the `@strategyeng!` macro (or the `@contractsenv!` macro for functions dealing with derivatives). Import your new trait, for example, `using .pp.Engine.Executors: MyNewTrait`.

Conform to the established argument order convention for the strategy signature:

```julia
function pong!(s::Strategy, [args...], ::MyNewTrade; kwargs...)
    # Implement the function body here
end
```

Follow these steps carefully to ensure the seamless integration of new `pong!` functions into the system.