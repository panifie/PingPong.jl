using .Lang: @preset, @precomp

@preset begin
    using .Lang: Logging
    @precomp begin
        ZarrInstance()
        zinstance()
    end
    isdefined(Data, :__init__) && @precomp __init__()
    empty!(zcache) # Need to empty otherwise compile cache keeps dangling pointers
    function makecandle(n)
        Candle(parse(TimeTicks.DateTime, "2020-01-0$n"), 1.0, 2.0, 0.5, 1.1, 123.0)
    end
    maketuple(c::Candle) = ((getproperty(c, p) for p in propertynames(c))...,)
    ohlcv_data = [makecandle(n) for n in (1, 2, 3)]
    exc_name = "abc"
    pair = "AAA/BBB:CCC"
    tfr = "1d"
    tmp_zi = Ref(zinstance(mktempdir()))
    args = (tmp_zi[], exc_name, pair, tfr)
    Logging.disable_logging(Logging.Error)
    try
        df = Ref{DataFrame}()
        @precomp df[] = df!((ohlcv_data))
        @precomp begin
            save_ohlcv(args..., df[])
            # double call
            save_ohlcv(args..., df[])
            save_ohlcv(args..., df[]; overwrite=true)
            save_ohlcv(args..., df[]; reset=true)
            # error handlers
            try
                save_ohlcv(args..., (); reset=true)
            catch
            end
        end
        push!(df[], maketuple(makecandle(4)))
        @precomp try
            save_ohlcv(args..., df[])
        catch
        end
        push!(df[], maketuple(makecandle(8)))
        @precomp try
            save_ohlcv(args..., df[])
        catch
        end
        @precomp begin
            load(args...; raw=false)
            load_ohlcv(args...; raw=false)
            load_ohlcv(args...; raw=true)
            load_ohlcv(args...; from="2020-01-01")
            # this should fail because there that date is not saved
            try
                load_ohlcv(args...; from="2020-02-01")
            catch
            end
            # this should fail because dates are not contiguous
            try
                load_ohlcv(args...; to="2020-01-03")
            catch
            end
        end
        @precomp begin
            default_value(Candle)
            candleat(df[], dt"2020-01-01")
            openat(df[], dt"2020-01-01")
            highat(df[], dt"2020-01-01")
            lowat(df[], dt"2020-01-01")
            closeat(df[], dt"2020-01-01")
            volumeat(df[], dt"2020-01-01")
            candleavl(df[], tf"1d", dt"2020-01-02")
            openavl(df[], tf"1d", dt"2020-01-02")
            highavl(df[], tf"1d", dt"2020-01-02")
            lowavl(df[], tf"1d", dt"2020-01-02")
            closeavl(df[], tf"1d", dt"2020-01-02")
            volumeavl(df[], tf"1d", dt"2020-01-02")
        end
        @precomp begin
            DFUtils.colnames(df[])
            DFUtils.firstdate(df[])
            DFUtils.lastdate(df[])
            try
                DFUtils.timeframe!(df[])
            catch
            end
        end
        pop!(df[])
        pop!(df[])
        @precomp df[][parse(DateRange, "2020-01-02..2020-01-03;1d")]
        prd = Minute(1)
        start_date = dt"2020-01-01"
        good_data = [(start_date += prd, prd) for _ in 1:3]
        bad_data = [(123, start_date += prd) for _ in 1:3]
        k = "somekey"
        @precomp begin
            save_data(tmp_zi[], k, good_data; serialize=true)
            try
                save_data(tmp_zi[], k, bad_data; serialize=true)
            catch
            end
            load_data(tmp_zi[], k; serialized=true, as_z=true)
            load_data(tmp_zi[], k; serialized=true)
        end
        k = "test_abc"
        @precomp begin
            Cache.__init__()
            Cache.save_cache(k, "abc")
            Cache.load_cache(k)
            Cache.delete_cache!(k)
        end
    finally
        Logging.disable_logging(Logging.Debug)
        if @load_preference("data_store", "lmdb") == "lmdb" && lm.LibLMDB.LMDB_jll.is_available()
            rm(tmp_zi[].store.a)
        end
    end
end
