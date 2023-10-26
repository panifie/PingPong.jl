@doc "Import the module directly. `Cache` does not export any function."
module Cache
using ..Data: tobytes, todata
using CodecZlib
using ..TimeTicks
using Misc: local_dir
const CACHE_PATH = Ref(local_dir("cache"))

function __init__()
    ispath(CACHE_PATH[]) || mkpath(CACHE_PATH[])
end

function save_cache(k, data; cache_path=CACHE_PATH[])
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

function load_cache(k; raise=true, agemax=nothing, cache_path=CACHE_PATH[])
    key_path = joinpath(cache_path, k)
    if !ispath(key_path)
        if raise
            throw(ArgumentError("Key $k does not exist."))
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

function delete_cache!(k; cache_path=CACHE_PATH[])
    rm(joinpath(cache_path, k); recursive=true)
end

end
