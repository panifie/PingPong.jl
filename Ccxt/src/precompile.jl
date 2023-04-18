# There isn't anything worth precompiling here
# we can't precompile init functions because python runtime
using SnoopPrecompile
@precompile_setup begin
    @precompile_all_calls begin
        __init__()
    end
    ccxt[] = nothing
    ccxt_ws[] = nothing
end
