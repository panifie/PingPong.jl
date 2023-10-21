using Executors: WatchOHLCV
using .Instances.Data: empty_ohlcv
using .Instances.Data.DFUtils: firstdate, setcols!
pong!(::Strategy{Sim}, ::WatchOHLCV) = nothing
pong!(::Strategy{Sim}, ::UpdateData) = nothing
function pong!(
    ::Function,
    s::Strategy{Sim},
    ::UpdateData;
    timeframe=s.timeframe,
    cols::Tuple{Vararg{Symbol}},
)
    nothing
end
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

function pong!(
    f::Function,
    s::Strategy{Sim},
    ::InitData;
    cols::Tuple{Vararg{Symbol}},
    timeframe=s.timeframe,
)
    _init_data(f, s, cols...; timeframe)
end
