using Test

macro deser!(v)
    v = esc(v)
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

function _test_save(k)
    z = Data.load_data(k; serialized=true)
    prevsz = size(z, 1)
    d1 = z[end, 1]
    wc.flush!(w)
    z = Data.load_data(k; serialized=true)
    newsz = size(z, 1)
    d2 = z[end, 1]
    @test d1 == d2 || newsz > prevsz
end

function _test_watchers_1()
    w = wi.cg_ticker_watcher("btc", "eth")
    @test w.name == "btceth"
    @test w.buffer isa DataStructures.CircularBuffer
    @test w.interval == Minute(6)
    @test w.flush_interval == Minute(6)
    wc.fetch!(w)
    @test length(w.buffer) > 0
    @test now() - (last(w.buffer).time) < Minute(12)
    _test_save("btceth")
end

function _test_watchers_2()
    w = wi.cg_derivatives_watcher("binance_futures")
    k = "cg_binance_futures_derivatives"
    @test w.name == k
    wc.fetch!(w)
    @test last(w).value isa Dict{wi.Derivative, wi.CgSymDerivative}
    _test_save(k)
end

test_watchers() = @testset "watchers" begin
    @eval begin
        using PingPong.Watchers
        using PingPong.Data
        using DataStructures
        using Serialization
        wc = Watchers
        wi = wc.WatchersImpls
    end
    _test_watchers_1()
    _test_watchers_2()
end
