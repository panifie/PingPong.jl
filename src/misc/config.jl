using Base: @kwdef

@kwdef mutable struct Config
    window::Int = 7
    timeframe::String = "1d"
    qc::String = "USDT"
    margin::Bool = false
    vol_min::Float64 = 10e4
    slope_min::Float64= 0.
    slope_max::Float64 = 90.
    ct::Dict{Symbol, NamedTuple} = Dict()
    attrs::Dict{Any, Any} = Dict()
end

const config = Config()

function resetconfig!()
    config.window = 7
    config.timeframe = "1d"
    config.qc = "USDT"
    config.margin = false
    config.vol_min = 10e4
    config.slope_min = 0.
    config.slope_max = 90.
    config.ct = Dict()
    config.attrs = Dict()
end

macro margin!()
    :(config.margin = !config.margin)
end

macro margin!!()
    :(config.margin = true)
end

setcfg!(k, v) = setproperty!(config, k, v)

resetconfig!()
