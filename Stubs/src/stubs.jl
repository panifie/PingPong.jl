using SimMode
using SimMode: Misc, Strategies, sml
using .Strategies
using .Strategies.Exchanges: Exchanges as exs, Instruments as im, Data, Python
using .Misc
using .Misc.TimeTicks
using .Misc.Lang
using .Data: Data as da, Cache as ca
using .Data.DataFrames: DataFrame
import .Data: stub!
using CSV: CSV as CSV
using Pkg: Pkg

const PROJECT_PATH = dirname(@something Base.ACTIVE_PROJECT[] Pkg.project().path)
const OHLCV_FILE_PATH = joinpath(PROJECT_PATH, "test", "stubs", "ohlcv.csv")

include("stub_strategy.jl")

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
function gensave_trades(n=10_000; s, dosave=true)
    for ai in s.universe
        da.stub!(ai, n)
    end
    SimMode.start!(s; doreset=true)
    if dosave
        for ai in s.universe
            save_stubtrades(ai)
        end
    end
end

function do_stub!(s::Strategy, n=10_000; trades=true)
    for ai in s.universe
        sml.stub!(ai, n)
    end
    if trades
        for ai in s.universe
            load_stubtrades!(ai)
        end
    end
    s
end

stub!(s::Strategy, n=10_000; trades=true) = do_stub!(s, n; trades)

function stub_strategy(mod=StubStrategy, args...; dostub=true, cfg=Config(), kwargs...)
    s = Strategies.strategy(mod, cfg; kwargs...)
    @assert s isa Strategy
    dostub && Stubs.do_stub!(s)
    s
end

@preset let
    Python.py_start_loop()
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
            # FIXME: on julia 1.10 an UndefVarError
            # happen during deserialization of trades
            try
                stub_strategy(; dostub=true)
            catch e
                if e isa UndefVarError
                    stub_strategy(; dostub=false)
                    @error "stubs: " exception = (first(Base.catch_stack())...,)
                else
                    rethrow(e)
                end
            end
        end
    end
    Python.py_stop_loop()
end
