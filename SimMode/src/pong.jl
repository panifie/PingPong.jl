using Executors: WatchOHLCV
using .Instances.Data: empty_ohlcv
using .Instances.Data.DFUtils: firstdate, setcols!
@doc "Watchers are not used in `SimMode`."
pong!(::Strategy{Sim}, ::WatchOHLCV; kwargs...) = nothing
@doc "Data should be pre initialized in `SimMode`."
pong!(::Strategy{Sim}, ::UpdateData; kwargs...) = nothing
@doc "Data should be pre initialized in `SimMode`."
function pong!(
    ::Function,
    s::Strategy{Sim},
    ::UpdateData;
    timeframe=s.timeframe,
    cols::Tuple{Vararg{Symbol}},
)
    nothing
end
@doc "Data should be pre initialized in `SimMode`."
function pong!(
    ::Function,
    s::Strategy{Sim},
    ai,
    ::UpdateData;
    timeframe=s.timeframe,
    cols::Tuple{Vararg{Symbol}},
)
    nothing
end

@doc """Initialize data for each asset in the strategy.

$(TYPEDSIGNATURES)

This function initializes data for each asset in the strategy by retrieving the OHLCV data and setting the specified columns. It uses the provided function `f` to process the OHLCV data and sets the columns of the `ohlcv` object accordingly. If the `ohlcv` object is empty, no data initialization is performed.

"""
function _init_data(f, s, cols...; timeframe)
    for ai in s.universe
        ohlcv = @lget! ohlcv_dict(ai) timeframe empty_ohlcv()
        if !isempty(ohlcv)
            new_data = f(ohlcv, firstdate(ohlcv))
            setcols!(ohlcv, new_data, cols)
            @deassert all(hasproperty(ohlcv, col) for col in cols)
        end
    end
end

@doc """Initialize data for each asset in the strategy.

$(TYPEDSIGNATURES)

This function initializes data for each asset in the strategy by retrieving the OHLCV data and setting the specified columns.

"""
function pong!(
    f::Function,
    s::Strategy{Sim},
    ::InitData;
    cols::Tuple{Vararg{Symbol}},
    timeframe=s.timeframe,
)
    _init_data(f, s, cols...; timeframe)
end
