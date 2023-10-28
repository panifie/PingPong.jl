using .ect.Lang: PrecompileTools, @preset, @precomp

# FIXME: This precompilation bloats the module
# maybe we should just input the precompile statements here.
@preset let
    using Stubs
    Stubs.py_start_loop()
    s = Stubs.stub_strategy()
    ai = first(s.universe)
    @precomp begin
        resample_trades(ai, tf"1d")
        resample_trades(s, tf"1d")
        trades_balance(ai; tf=tf"1d")
        trades_balance(s; tf=tf"1d")
    end
    Stubs.py_stop_loop()
end
