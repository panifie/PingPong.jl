# There isn't anything worth precompiling here
# we can't precompile init functions because python runtime
using PrecompileTools
@setup_workload begin
    @compile_workload begin
        __init__()
        _lazypy(ccxt, "ccxt.async_support")
        _lazypy(ccxt_ws, "ccxt.pro")
    end
    # Important to not leave dangling pointers in the cache
    ccxt[] = nothing
    ccxt_ws[] = nothing
    Python.py_stop_loop()
end
