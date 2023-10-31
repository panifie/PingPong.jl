using PrecompileTools

@setup_workload @compile_workload begin
    include("consts.jl")
    Config()
    Dict{String,Any}()
    __init__()
    OFFLINE[] = false
end
