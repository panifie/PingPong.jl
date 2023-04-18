module Stubs

using CSV: CSV as CSV
isdefined(@__MODULE__, :Pkg) || using Pkg: Pkg
if !isdefined(@__MODULE__, :DataFrames)
    try
        using ..DataFrames: DataFrame
    catch
        using DataFrames: DataFrame
    end
end

const PROJECT_PATH = dirname(@something Base.ACTIVE_PROJECT[] Pkg.project().path)
const OHLCV_FILE_PATH = joinpath(PROJECT_PATH, "test", "stubs", "ohlcv.csv")

read_ohlcv() = CSV.read(OHLCV_FILE_PATH, DataFrame)

function remove_loadpath!(path)
    try
        deleteat!(findfirst(x -> x == "Instances", LOAD_PATH), LOAD_PATH)
    catch
    end
end

function stubscache_path()
    proj = Pkg.project()
    @assert proj.name == "PingPong"
    joinpath(dirname(proj.path), "test", "stubs")
end

function save_stubtrades(ai)
    @eval using Data: Cache as ca
    ca.save_cache("trades_stub_$(ai.asset.bc)", ai.history; cache_path=stubscache_path())
end

function save_strategy(s)
    @eval using Data: Cache as ca
    ca.save_cache("strategy_stub_$(nameof(s))", s; cache_path=stubscache_path())
end

function load_stubtrades(ai)
    @eval using Data: Cache as ca
    ca.load_cache("trades_stub_$(ai.asset.bc)"; cache_path=stubscache_path())
end

function load_strategy(name)
    @eval using Data: Cache as ca
    ca.load_cache("strategy_stub_$(name)"; cache_path=stubscache_path())
end

function load_stubtrades!(ai)
    trades = load_stubtrades(ai)
    append!(ai.history, trades)
end

function gensave_trades()
    try
        push!(LOAD_PATH, "OrderTypes")
        @eval using PingPong
        @eval @environment!
        @eval begin

            s = st.strategy(:Example)
            save_strategy(s)
            for ai in s.universe
                da.stub!(ai, 100_000)
            end
            bt.backtest!(s)
            for ai in s.universe
                save_stubtrades(ai)
            end
            s
        end
    finally
        remove_loadpath!("OrderTypes")
    end
end

end
