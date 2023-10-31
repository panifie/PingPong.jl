# There isn't anything worth precompiling here
# we can't precompile init functions because python runtime
using PrecompileTools
@setup_workload begin
    @compile_workload begin
        __init__()
    end
    _lazypy(ccxt, "ccxt.async_support")
    _lazypy(ccxt_ws, "ccxt.pro")
    # Important to not leave dangling pointers in the cache
    ccxt[] = Python.PyNULL
    ccxt_ws[] = Python.PyNULL
    Python.py_stop_loop()
end
