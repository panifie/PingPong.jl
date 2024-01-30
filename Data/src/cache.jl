@doc """A module for caching data.

The `Cache` module provides functions and types for caching data. It includes the following functions:
- `save_cache(k, data)`: Saves the given data to the cache with the specified key.
- `load_cache(k)`: Loads the cached data corresponding to the specified key.
- `delete_cache!(k)`: Deletes the cached data corresponding to the specified key.

The module also defines the following constant:
- `CACHE_PATH`: The path to the cache directory.

To use it import the functions (or the module) directly.
"""
module Cache
using ..Data: tobytes, todata
using CodecZlib
using ..TimeTicks
using Misc: local_dir
using Misc.DocStringExtensions
const CACHE_PATH = Ref(local_dir("cache"))

function __init__()
    ispath(CACHE_PATH[]) || mkpath(CACHE_PATH[])
end

@doc """Save data to the cache.

$(TYPEDSIGNATURES)

- `k`: The key under which to save the data.
- `data`: The data to be saved.
- `cache_path`: The path to the cache directory. Default is `CACHE_PATH[]`.
"""
function save_cache(k, data; cache_path=nothing)
    cache_path = @something cache_path CACHE_PATH[]
    key_path = joinpath(cache_path, k)
    let dir = dirname(key_path)
        ispath(dir) || mkpath(dir)
    end
    bytes = tobytes(data)
    compressed = transcode(GzipCompressor, bytes)
    open(key_path, "w") do f
        write(f, compressed)
    end
end

@doc """Load cached data.

$(TYPEDSIGNATURES)

- `k`: The key corresponding to the cached data.
- `raise`: If set to `true`, an `ArgumentError` will be thrown if the key does not exist. Default is `true`.
- `agemax`: The maximum age (in seconds) allowed for the cached data. If the data is older than `agemax`, an `ArgumentError` will be thrown. Default is `nothing`.
- `cache_path`: The path to the cache directory. Default is `CACHE_PATH[]`.

Returns the cached data if it exists and meets the age criteria, or `nothing` otherwise.
"""
function load_cache(k; raise=true, agemax=nothing, cache_path=nothing)
    key_path = joinpath(@something(cache_path, CACHE_PATH[]), k)
    if !ispath(key_path)
        if raise
            throw(ArgumentError("Path $key_path does not exist."))
        else
            return nothing
        end
    end
    if !isnothing(agemax)
        age = now() - unix2datetime(stat(key_path).mtime)
        if age > agemax # TODO: what is the timezone returned by mtime?
            if raise
                throw(ArgumentError("Key $k data is older than $agemax."))
            end
            return nothing
        end
    end
    bytes = read(key_path)
    transcode(GzipDecompressor, bytes) |> todata
end

@doc """Delete the cached data corresponding to the specified key.

$(TYPEDSIGNATURES)

- `k`: The key corresponding to the cached data.
- `cache_path`: The path to the cache directory. Default is `CACHE_PATH[]`.
"""
function delete_cache!(k; cache_path=CACHE_PATH[])
    rm(joinpath(cache_path, k); recursive=true)
end

end
