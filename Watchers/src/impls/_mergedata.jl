@doc "Fetch the date from a `Vector{Candle}` where `f` chooses the index."
_dateat(data, idx) = data[idx].timestamp
_firstdate(data) = _dateat(data, firstindex(data))
_lastdate(data) = _dateat(data, lastindex(data))

function appenddict!(d::Dict{K,<:AbstractVector{V}}, k, v) where {K,V}
    vec = @lget! d k V[]
    append!(vec, v)
end

function _first(data::AbstractVector{BufferEntry(T)}) where {T<:AbstractDict}
    first((first(data).value)).second |> first
end

function _merge_data(buf::AbstractVector, tf::TimeFrame)
    isempty(buf) && return nothing
    iscomplete(_first(buf), tf) || return nothing
    @assert typeof(first(buf).value) <: Dict{String,Vector{Candle}} "type was: $(eltype(buf))"
    # concat all the ticks symbol wise
    data = first(buf).value
    for i in Iterators.drop(eachindex(buf), 1)
        for k in keys(buf[i].value)
            if iscomplete(first(buf[i].value[k]), tf)
                if iscomplete(last(buf[i].value[k]), tf)
                    appenddict!(data, k, buf[i].value[k])
                else # data trails with an incomplete candle ticks
                    incomplete_begin = 0
                    for t in eachindex(buf[i].value[k])
                        iscomplete(buf[i].value[k][t], tf) && continue
                        incomplete_begin = t
                        break
                    end
                    incomplete_begin > 0 && appenddict!(
                        data, k, @view(buf[i].value[k][begin:(incomplete_begin - 1)])
                    )
                end
            else
                break
            end
        end
    end
    return cleanup_ohlcv_data(first(data).second, string(tf))
    for k in keys(data)
        @with cleanup_ohlcv_data(data[k], tf) begin
            data[k] = Candle.(:timestamp, :open, :high, :low, :close, :volume)
        end
    end
    data
    # doappend(p) = appenddict!(data, p.first, p.second)
    # dofe(x) = foreach(doappend, x.value)
    # foreach(dofe, buf)
end
