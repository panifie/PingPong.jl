using .Lang: @preset, @precomp

@preset let
    ExchangeTypes.Python.py_start_loop()
    @precomp let
        strategy(:BareStrat, parent_module=Strategies)
    end
    s = strategy(:BareStrat, parent_module=Strategies)
    @precomp begin
        assets(s)
        instances(s)
        exchangeid(typeof(s))
        freecash(s)
        execmode(s)
        nameof(s)
        nameof(typeof(s))
        reset!(s)
        propertynames(s)
        attrs(s)
        s.attrs
        coll.iscashable(s)
        minmax_holdings(s)
        trades_count(s)
        orders(s, Buy)
        orders(s, Sell)
        show(devnull, s)
    end
    ExchangeTypes._closeall()
    ExchangeTypes.Python.py_stop_loop()
end
