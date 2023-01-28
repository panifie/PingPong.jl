# using Pkg

# proj = Pkg.project()

# # NOTE: CompileBot is added as a test dependency, and test dir is added as a LOAD_PATH entry.
# let lpath = joinpath(dirname(proj.path), "../", "test")
#     lpath ∉ LOAD_PATH && push!(LOAD_PATH, lpath)
# end

using CompileBot

botconfig = BotConfig(
  "PingPong";                            # package name (the one this configuration lives in)
    os = ["linux"],
  # yml_path = "SnoopCompile.yml"        # parse `os` and `version` from `SnoopCompile.yml`
  exclusions = [""],        # exclude functions (by name) that would be problematic if precompiled
)

snoop_bot(
  botconfig,
  "$(@__DI __)/script.jl",
)

