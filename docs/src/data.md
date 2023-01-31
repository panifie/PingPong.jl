# Data

The main backend currently is Zarr. Zarr is similar to feather or parquet in that it optimizes to columnar data, or in general _arrays_. However it is simpler, and allows to pick different encoding schemes, and supports compression by default. More over the zarr interface can be backed by different storage layers, that can also be over the network. Compared to no/sql databases columnar storage has the drawback of having to read _chunks_ for queries, but we are almost never are interested in scalar values, we always query a time-series of some sort, so the latency loss is a non issue.

```@autodocs
Modules = [PingPong.Data]
```

# Prices

```@autodocs
Modules = [Prices]
```
