# NOTE: CompileBot is added as a test dependency, and test dir is added as a LOAD_PATH entry.
# let lpath = joinpath(dirname(Pkg.project().path), "test")
#     lpath ∉ LOAD_PATH && push!(LOAD_PATH, lpath)
# end

# cd(dirname(Pkg.project().path))

using CompileBot

botconfig = BotConfig(
    "Cli";                            # package name (the one this configuration lives in)
    os=["linux"],
    # yml_path = "SnoopCompile.yml"        # parse `os` and `version` from `SnoopCompile.yml`
    exclusions=[""],        # exclude functions (by name) that would be problematic if precompiled
)

snoop_bot(botconfig, "$(@__DIR__)/script.jl")
