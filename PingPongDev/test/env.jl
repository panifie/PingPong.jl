EXCHANGE = Symbol(get!(ENV, "PINGPONG_TEST_EXCHANGE", :binance))
EXCHANGE_MM = Symbol(@something get(ENV, "PINGPONG_TEST_EXCHANGE_MM", nothing) :binanceusdm)
# Skip heavy precomp during tests
ENV["JULIA_PRECOMP"] = ""
# Tests rely on output consistency
ENV["JULIA_DEBUG"] = ""
# Disable TMP project path
NO_TMP = "JULIA_NO_TMP" ∈ keys(ENV)
if NO_TMP
    using Pkg: Pkg
    # activate main project
    root = "."
    if isnothing(Pkg.project().name) && ispath(joinpath(dirname(pwd()), "Project.toml"))
        root = ".."
    end
    Pkg.activate(root)
    @assert Pkg.project().name == "PingPongDev"
    if ispath(joinpath(root, ".CondaPkg", "env"))
        ENV["JULIA_CONDAPKG_OFFLINE"] = "yes"
    end
end

using PingPongDev
using PingPongDev.PingPong.Engine.Instances.Exchanges.Python.PythonCall.GC: enable as gc_enable, disable as gc_disable

PROJECT_PATH = pathof(PingPongDev) |> dirname |> dirname
push!(LOAD_PATH, dirname(PROJECT_PATH))
FAILFAST = true # parse(Bool, get(ENV, "FAILFAST", "0"))

const _INCLUDED_TEST_FILES = Set{String}()
