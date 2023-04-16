using Lang: @preset, @precomp
@preset let
    e = :bybit
    @precomp begin
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
    @precomp Exchange(ccxt[].bybit())
    e = Exchange(ccxt[].bybit())
    @precomp begin
        hash(e)
        e.has
    end
end
