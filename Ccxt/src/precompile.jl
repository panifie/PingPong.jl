# There isn't anything worth precompiling here
# we can't precompile init functions because python runtime
using PrecompileTools
@setup_workload begin
    @compile_workload begin
        __init__()
    end
    ccxt[] = nothing
    ccxt_ws[] = nothing
    Python.py_stop_loop()
end
