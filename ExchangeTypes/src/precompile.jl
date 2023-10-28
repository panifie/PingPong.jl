using Ccxt.Misc.Lang: @preset, @precomp
@preset let
    using .Python: pyfetch
    e = :bybit
    @precomp begin
        Python.py_start_loop()
        __init__()
        ExchangeID(e)
    end
    id = ExchangeID(e)
    @precomp begin
        nameof(id)
        string(id)
        id.sym
        id == :bybit
        convert(Symbol, id)
        convert(String, id)
    end
    @precomp let
        e = Exchange(ccxt[].bybit())
        pyfetch(e.close)
    end
    e = Exchange(ccxt[].bybit())
    @precomp begin
        hash(e)
        e.has
    end
    pyfetch(e.close)
    _closeall()
    Python.py_stop_loop()
end
