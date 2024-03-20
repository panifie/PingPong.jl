using Test
# using .PingPong.Data.DFUtils
# include("env.jl")
# btc = first(s.universe, a"BTC/USDT")
#

test_zarrinstance() = begin
    zi = Data.zinstance()
    @test zi isa ZarrInstance
    @test zi.store isa Data.LMDBDictStore
    @test startswith(zi.store.a.env.path, Data.DATA_PATH)
    zi
end

function test_save_json(zi=nothing, key="coingecko/markets/all")
    @eval begin
        using PingPongDev.Misc.JSON
        using Mmap
    end
    filepath = joinpath(PROJECT_PATH, "test/stubs/cg_markets.json")
    data = JSON.parsefile(filepath)
    if isnothing(zi)
        zi = zinstance()
    end
    sz = (length(data), 2)
    za, existing = da._get_zarray(zi, key, sz; type=String, overwrite=true, reset=true)
    resize!(za, sz)
    @test za.metadata.chunks == (length(data), 2)
    @test existing isa Bool
    v = [[(v["last_updated"]), JSON.json(v)] for v in values(data)]
    v = reduce(hcat, v) |> permutedims
    za[:, :] = v[:, :]
    n = length(data)
    for x in (1, n ÷ 2, n), y in (1, 2)
        @test za[x, y] == v[x, y]
    end
end

function test_zarray_save(zi)
    sz = (123, 3)
    k = string(rand())
    z, existing = da._get_zarray(zi, k, sz; type=String, overwrite=true, reset=true)
    try
        @test !existing
        @test z isa ZArray
        @test eltype(z) == String
        @test z.metadata.chunks == (123, 3)
        @test length(z) == 0
        @test size(z) == (0, 3)
    finally
        delete!(z)
        Main.z = z
    end
    return z
end

test_data() = @testset "data" failfast = FAILFAST begin
    @eval begin
        using .PingPong.Engine.Data
        if !isdefined(@__MODULE__, :da)
            da = Data
        end
        using .Data.Zarr
        if !isdefined(@__MODULE__, :za)
            za = Zarr
        end
    end
    zi = test_zarrinstance()
    test_zarray_save(zi)
    test_save_json(zi)
end
