@doc "Import the module directly. `Cache` does not export any function."
module Cache
using TimeTicks
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

function load_cache(k; raise=true, agemax=nothing)
    key_path = joinpath(CACHE_PATH[], k)
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

function delete_cache!(k)
    rm(joinpath(CACHE_PATH[], k); recursive=true)
end

end
