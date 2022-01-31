using Base: @kwdef

@kwdef mutable struct Config
    window::Int = 7
    timeframe::String = "1d"
    qc::String = "USDT"
    margin::Bool = false
    leverage::Symbol = :no
    vol_min::Float64 = 10e4
    slope_min::Float64= 0.
    slope_max::Float64 = 90.
    ct::Dict{Symbol, NamedTuple} = Dict()
    attrs::Dict{Any, Any} = Dict()
end

const config = Config()

function resetconfig!()
    default = Config()
    for k in fieldnames(Config)
        setproperty!(config, k, getproperty(default, k))
    end
end

macro margin!()
    :(config.margin = !config.margin)
end

macro lev!()
    :(config.leverage = !config.leverage)
end

setcfg!(k, v) = setproperty!(config, k, v)

resetconfig!()
