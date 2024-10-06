using .ect.Lang: PrecompileTools, @preset, @precomp, @ignore

# FIXME: This precompilation bloats the module
# maybe we should just input the precompile statements here.
@preset let
    using Stubs
    Stubs.exs.Python.py_start_loop()
    # FIXME: see Stubs pkg precomp fixme
    s = Stubs.stub_strategy(dostub=false)
    ai = first(s.universe)
    @precomp @ignore begin
        resample_trades(ai, tf"1d")
        resample_trades(s, tf"1d")
        trades_balance(ai; tf=tf"1d")
        trades_balance(s; tf=tf"1d")
    end
    Stubs.exs.Python.py_stop_loop()
end
