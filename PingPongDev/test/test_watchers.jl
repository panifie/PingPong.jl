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

function _test_save(k, w)
    z = Data.load_data(k; serialized=true)
    prevsz = size(z, 1)
    d1 = prevsz[1] > 0 ? z[end, 1] : NaN
    wa.flush!(w)
    z = Data.load_data(k; serialized=true)
    newsz = size(z, 1)
    d2 = z[end, 1]
    @test d1 == d2 || newsz > prevsz
end

function _test_watchers_1()
    w = wi.cg_ticker_watcher("btc", "eth")
    @test w.name == "cg_ticker-7224535830704663454"
    @test w.buffer isa DataStructures.CircularBuffer
    @test w.interval.flush == Minute(6)
    @test w.interval.flush == Minute(6)
    wa.fetch!(w)
    if wi.cg.STATUS[] == 200
        @test length(w.buffer) > 0
        @test now() - (last(w.buffer).time) < Minute(12)
        _test_save("cg_ticker_btc_eth", w)
    end
end

function _test_watchers_2()
    w = wi.cg_derivatives_watcher("binance_futures")
    @test w.name == "cg_derivatives-16819285695551769070"
    wa.fetch!(w)
    if wi.cg.STATUS[] == 200
        @test last(w).value isa Dict{wi.Derivative,wi.CgSymDerivative}
        k = "cg_binance_futures_derivatives"
        _test_save(k, w)
    end
end

test_watchers() = @testset failfast = FAILFAST "watchers" begin
    @eval begin
        using .PingPong.Engine.LiveMode.Watchers
        using .PingPong.Data
        using .PingPong.Data.DataStructures
        using .PingPong.Data.Serialization
        wa = Watchers
        isdefined(@__MODULE__, :wi) || (wi = wa.WatchersImpls)
    end
    _test_watchers_1()
    _test_watchers_2()
end
