using Engine: SimMode
using Engine.TimeTicks
using Engine.Misc
using Engine.Simulations: Simulations as sim
using Engine.Strategies
using Exchanges: Exchanges as exs, Instruments as im
using Data: Data as da
using Data.DataFrames: DataFrame
using Data: Cache as ca
import Data: stub!
using CSV: CSV as CSV
using Pkg: Pkg
using Lang

const PROJECT_PATH = dirname(@something Base.ACTIVE_PROJECT[] Pkg.project().path)
const OHLCV_FILE_PATH = joinpath(PROJECT_PATH, "test", "stubs", "ohlcv.csv")

read_ohlcv() = CSV.read(OHLCV_FILE_PATH, DataFrame)

function stubscache_path()
    proj = Pkg.project()
    joinpath(dirname(dirname(proj.path)), "PingPong", "test", "stubs")
end

function save_stubtrades(ai)
    ca.save_cache(
        "trades_stub_$(ai.asset.bc).jls", ai.history; cache_path=stubscache_path()
    )
end

# Strategy can't be saved because it has a module property and modules can't be deserialized
# function save_strategy(s)
#     ca.save_cache("strategy_stub_$(nameof(s))", s; cache_path=stubscache_path())
# end
# function load_strategy(name)
#     ca.load_cache("strategy_stub_$(name)"; cache_path=stubscache_path())
# end

function load_stubtrades(ai)
    ca.load_cache("trades_stub_$(ai.asset.bc).jls"; cache_path=stubscache_path())
end

function load_stubtrades!(ai)
    trades = load_stubtrades(ai)
    append!(ai.history, trades)
end

@doc "Generates trades and saves them to the stubs shed."
function gensave_trades(n=10_000; s=Strategies.strategy(:Example), dosave=true)
    for ai in s.universe
        da.stub!(ai, n)
    end
    SimMode.start!(s, doreset=true)
    if dosave
        for ai in s.universe
            save_stubtrades(ai)
        end
    end
end

function do_stub!(s::Strategy, n=10_000; trades=true)
    for ai in s.universe
        sim.stub!(ai, n)
    end
    if trades
        for ai in s.universe
            load_stubtrades!(ai)
        end
    end
    s
end

stub!(s::Strategy, n=10_000; trades=true) = do_stub!(s, n; trades)

include("../../PingPong/test/stubs/Example.jl")
function stub_strategy(mod=nothing, args...; dostub=true, cfg=nothing, kwargs...)
    isnothing(cfg) && (cfg = Misc.Config())
    if isnothing(mod)
        p = get(ENV, "PINGPONG_PATH", "/pingpong/PingPong")
        ppath = if isdir(p)
            p
        elseif basename(realpath(".")) == "PingPong"
            realpath(".")
        elseif isdir("./PingPong")
            realpath("./PingPong")
        end
        cfg.attrs["include_file"] = realpath(joinpath(ppath, "test/stubs/Example.jl"))
        mod = Example
    end
    s = Strategies.strategy!(mod, cfg, args...; kwargs...)
    @assert s isa Strategy
    dostub && Stubs.do_stub!(s)
    s
end

@preset let
    @precomp let
        try
            s = stub_strategy()
            gensave_trades(; s, dosave=false)
        catch
            s = stub_strategy(; dostub=false)
            while any(isempty(ai.history) for ai in s.universe)
                gensave_trades(; s, dosave=false)
            end
            for ai in s.universe
                save_stubtrades(ai)
            end
            stub_strategy(; dostub=true)
        end
    end
end
