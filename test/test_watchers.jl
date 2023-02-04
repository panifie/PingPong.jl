using Test

macro deser!(v)
    quote
        buf = IOBuffer($v)
        try
            v = deserialize(buf)
            take!(buf)
            v
        finally
            close(buf)
        end
    end
end

function _test_watchers_1()
    w = wi.cg_ticker_watcher("btc", "eth")
    @test w.name == "btceth"
    @test w.name == "btceth"
    @test w.buffer isa DataStructures.CircularBuffer
    @test w.interval == Minute(6)
    @test w.flush_interval == Minute(6)
    wc.fetch!(w)
    @test length(w.buffer) > 0
    @test now() - (last(w.buffer).time) < Minute(12)
    z = Data.load_data("btceth"; serialized=true)
    prevsz = size(z, 1)
    d1 = @deser! z[end, 1]
    wc.flush!(w)
    z = Data.load_data("btceth"; serialized=true)
    newsz = sice(z, 1)
    d2 = @deser! z[end, 1]
    @test d1 == d2 || newsz > prevsz
end

test_watchers() = @testset "watchers" begin
    @eval begin
        using PingPong.Watchers
        using PingPong.Data
        using DataStructures
        using Serialization
        wc = Watchers
        wi = WatchersImpls
    end
    @test begin
        _test_watchers_1()
    end
end
