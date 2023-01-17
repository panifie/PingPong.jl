import Zarr;
const za = Zarr;
import LMDB;
const lm = LMDB;

struct LMDBDictStore <: za.AbstractDictStore
    a::lm.LMDBDict
    LMDBDictStore(path::AbstractString) = begin
        !ispath(path) && mkpath(path)
        new(lm.LMDBDict{String,Vector{UInt8}}(path))
    end
end

Base.filter!(f, d::lm.LMDBDict) = begin
    collect(v for v in pairs(d) if f(v))
end
