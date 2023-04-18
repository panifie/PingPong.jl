using SnoopPrecompile
SnoopPrecompile.verbose[] = true

@precompile_setup @precompile_all_calls begin
    Config()
    Dict{String,Any}()
    __init__()
end
