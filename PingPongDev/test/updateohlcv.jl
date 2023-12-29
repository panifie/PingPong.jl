using Test

function test_update_ohlcv_1(s)
    ai = first(s.universe)
    tf = s.timeframe
    od = ohlcv_dict(ai)
    delete!(od, tf)
    ohlcv = od[tf] = da.empty_ohlcv()
    @assert isempty(ohlcv)
    delete!(s.attrs, :lastdate_updates)
    lm.update!(s, ai, :a, :b) do ohlcv, from_date
        # Do nothing
    end
    @test !hasproperty(ohlcv, :a)
    @test !hasproperty(ohlcv, :b)
    append!(ohlcv_dict(ai)[tf], da.to_ohlcv(sml.synthohlcv()); cols=:union)
    first_date = lm.firstdate(ohlcv)
    rows = da.nrow(ohlcv)
    this_update = Ref{Any}()
    @assert !isempty(ohlcv_dict(ai)[tf])
    @info "test" objectid(ohlcv_dict(ai)[tf])
    lm.update!(s, ai, :a, :b) do ohlcv, from_date
        @info "TEST: " lm.firstdate(ohlcv) lm.lastdate(ohlcv) from_date
        from_idx = lm.dateindex(ohlcv, from_date, :nonzero)
        @test from_date == first_date
        this_update[] = rand(length(from_idx:da.nrow(ohlcv)), 2)
    end
    ohlcv = ohlcv
    @test rows == da.nrow(ohlcv)
    @test lm.firstdate(ohlcv) == first_date
    @test hasproperty(ohlcv, :a)
    @test hasproperty(ohlcv, :b)
    @test ohlcv.a == this_update[][:, 1]
    @test ohlcv.b == this_update[][:, 2]
    append!(
        ohlcv,
        da.to_ohlcv(sml.synthohlcv(; start_date=lm.lastdate(ohlcv) + s.timeframe));
        cols=:union,
    )
    @test da.nrow(ohlcv) == 2002

    @test_warn "no new data" lm.update!(s, ai, :a, :b) do ohlcv, from_date
        # ohlcv is empty
    end

    tf = timeframe(ohlcv)
    od[tf] = da.empty_ohlcv()
    ohlcv = od[tf]

    @test_warn "wrong number" lm.update!(s, ai, :a, :b) do ohlcv, from_date
        a = rand(da.nrow(ohlcv))
        b = rand(da.nrow(ohlcv))
        ohlcv.a = a
        ohlcv.b = b
    end
    @test !hasproperty(ohlcv, :a)
    @test !hasproperty(ohlcv, :b)

    delete!(s.attrs, :lastdate_updates)
    @test_warn "missing entries" lm.update!(s, ai, :a, :b) do ohlcv, from_date
        n = lm.nrow(ohlcv)
        rand(n - 100, 2)
    end

    delete!(s.attrs, :lastdate_updates)
    @test_warn "keeping end" lm.update!(s, ai, :a, :b) do ohlcv, from_date
        n = lm.nrow(ohlcv)
        rand(n + 100, 2)
    end
end

test_update_ohlcv() = begin
    @eval using Random
    @testset "update ohlcv" begin
        Random.seed!(1)
        s = loadstrat!(:BollingerBands; mode=Live(), exchange=:phemex)
        test_update_ohlcv_1()
    end
end
