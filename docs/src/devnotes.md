## Precompilations
Functions that should be precompiled
- Python: `clearpath!`
- Data: `ZarrInstance`, `ZGroup`, `zopen`, `get_zgroup`
- Misc: `empty!(::Config)`
- CPython `__init__`(?)

Precompilation can be skipped for some modules, by setting `JULIA_NOPRECOMP` env var:
```julia
ENV["JULIA_NOPRECOMP"] = (:PingPong, :Scrapers, :Engine, :Watchers, :Plotting, :Stats)
```
