The bot focuses on crypto trading but you might want to use it for stock trading and plug it to brokers apis. 
You need to use a different `Exchange` implementation. 

``` julia
struct MyBroker <: Exchange
...
end
```

To get an overview of what is necessary to swap the main exchange struct you can look at the `check` function defined in the `Exchanges` module. Admittedly you might find implementing a compatible `Exchange` class not worth it compared to adding broker support directly into CCXT for the cost of paying the python round trip.

Eventually pingpong might get direct DEX support, either by plugging hummingbot connector middleware or by custom bot-to-node api implementations or through CCXT, depending on how CCXT might evolve.
