@doc "Import the module directly. `Cache` does not export any function."
module Cache
using Misc: local_dir
using CodecZlib
using ..Data: tobytes, todata
const CACHE_PATH = Ref(local_dir("cache"))

function __init__()
    ispath(CACHE_PATH[]) || mkpath(CACHE_PATH[])
end

function save_cache(k, data)
    key_path = joinpath(CACHE_PATH[], k)
    let dir = dirname(key_path)
        ispath(dir) || mkpath(dir)
    end
    bytes = tobytes(data)
    compressed = transcode(GzipCompressor, bytes)
    open(key_path, "w") do f
        write(f, compressed)
    end
end

function load_cache(k; raise=true)
    key_path = joinpath(CACHE_PATH[], k)
    if !ispath(key_path)
        if raise
            throw(ArgumentError("Key $k does not exist."))
        else
            return nothing
        end
    end
    bytes = read(key_path)
    transcode(GzipDecompressor, bytes) |> todata
end

function delete_cache!(k)
    rm(joinpath(CACHE_PATH[], k); recursive=true)
end

end
