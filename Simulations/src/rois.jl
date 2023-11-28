using .Misc: Iterable

# TYPENUM
@doc """ A struct representing a Region of Interest (ROI) with targets and timeouts.

$(FIELDS)

`Roi` is a struct that holds targets and timeouts as NTuples, along with a timeframe. 
The targets and timeouts are sorted in the constructor.
The timeframe is used to round the timeouts and is defaulted to "1m".
The struct is parameterized by the type `T` of the targets and the number `N` of targets and timeouts.

"""
struct Roi5{T,N}
    targets::NTuple{N,T}
    timeouts::NTuple{N,Period}
    timeframe::TimeFrame
    """
    Function `Roi(tups; timeframe=tf"1m")`

    Constructs a `Roi` struct with targets and timeouts from `tups`.
    - `tups`: an iterable of tuples representing targets and timeouts.
    - `timeframe`: the timeframe used to round the timeouts (default: "1m").

    $(FIELDS)

    The function sorts the targets and timeouts based on the rounded timeouts and constructs a `Roi` struct.
    Example:
    ```julia
    tups = [(1, 2), (3, 4)]
    roi = Roi(tups)
    """
    function Roi5(tups; timeframe=tf"1m")
        values = collect(tups)
        T = typeof(values[1][1])
        N = length(values)
        # round
        timeouts = [round(v[2], timeframe.period) for v in values]
        # sorted index
        sorted_idx = sortperm(timeouts)
        new{T,N}(
            tuple((values[i][1] for i in sorted_idx)...),
            # construct sorted tuple
            tuple((timeouts[i] for i in sorted_idx)...),
            timeframe,
        )
    end
    @doc """Define a `Roi` struct with targets and timeouts from `tups`.

    $(TYPEDSIGNATURES)

    The function constructs a `Roi` struct with targets and timeouts from `tups`.
    - `tups`: an iterable of tuples representing targets and timeouts.
    - `timeframe`: the timeframe used to round the timeouts (default: "1m").
    """
    Roi5(targets, timeouts; timeframe=tf"1m") = Roi5(zip(targets, timeouts); timeframe)
end
Roi = Roi5

_roigetindex(r, i) = (r.targets[i], r.timeouts[i])
_roilen(r) = length(r.targets)
_roilastindex(r) = lastindex(r.targets)
Base.getindex(r::Roi, i) = _roigetindex(r, i)
Base.length(r::Roi) = _roilen(r)
Base.lastindex(r::Roi) = _roilastindex(r)

# TYPENUM
@doc """Defines a `RoiInverted` struct with `targets`, `timeouts`, and `timeframe`.

$(FIELDS)

The `RoiInverted` struct represents an inverted ROI, where the targets and timeouts are reversed.
Example:
```julia
roi = RoiInverted(targets, timeouts, timeframe)
```
"""
struct RoiInverted1{N,T}
    targets::NTuple{N,T}
    timeouts::NTuple{N,Period}
    timeframe::TimeFrame
    @doc """Defines a `RoiInverted` struct with reversed `targets`, `timeouts`, and `timeframe`.

    $(TYPEDSIGNATURES)

    Constructs a `RoiInverted` struct by reversing the `targets` and `timeouts` of an input `Roi` struct.
    """
    function RoiInverted1(roi::Roi{T,N}) where {N,T}
        new{N,T}(reverse(roi.targets), reverse(roi.timeouts), roi.timeframe)
    end
end
RoiInverted = RoiInverted1
Base.getindex(r::RoiInverted, i) = _roigetindex(r, i)
Base.length(r::RoiInverted) = _roilen(r)
Base.lastindex(r::RoiInverted) = _roilastindex(r)

@doc """Calculates the weighted ROI based on elapsed time, targets, and timeouts.

$(TYPEDSIGNATURES)

The function calculates the weighted ROI by linearly interpolating between the current target and the next target based on the ratio of the elapsed time between the current and next timeouts. 
Returns the weighted ROI.
"""
function roiweight(elapsed, target, timeout, next_target, next_timeout)
    timespan = next_timeout - timeout
    next_ratio = timespan > Second(0) ? (elapsed - timeout) / timespan : 1
    ratio = 1 - max(0, next_ratio)
    return target * ratio + next_target * next_ratio
end
function roiweight(timeframe::TimeFrame, frames, args...)
    roiweight(timeframe * frames, args...)
end

"""
Checks if roi has been triggered according to a target profit and a *sorted* vector (profit, timeout) tuples.

$(TYPEDSIGNATURES)

Example roi: [(0.1, 3), (0.05, 5), (0.025, 10)]
In this case 3,5,10 are the timeouts, expressed in timeframes counts. E.g. if the timeframe is 2m then the timeouts
would effectively be 6m,10m,20m.
The profit targets 0.1,0.05,0.025 are instead expressed in percentage of the trade value.
Note how _usually_ with smaller timeouts you expect higher profits, and as time progresses, you settle with lower
ones, (or even negative ones, which would act as a stoploss.)
"""
function isroi(frames, target, roii::RoiInverted)
    elapsed = frames * roii.timeframe.period
    # checking for roi is always done in reverse
    # otherwise the first one would always trigger
    for (t, tm) in Iterators.drop(enumerate(roii.timeouts), 1)
        if tm <= elapsed
            next_t = t > 1 ? t - 1 : t
            weighted_target = roiweight(
                elapsed,
                # current roi target target
                roii.targets[t],
                # current roi timeout
                tm,
                # next roi value
                roii.targets[next_t],
                # next roi timeout
                roii.timeouts[next_t],
            )
            target >= weighted_target && return (true, weighted_target)
        end
    end
    return (false, NaN)
end
