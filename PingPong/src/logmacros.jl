using Engine.Executors: Strategy

_logmsg(::Strategy{Sim}, val, msg; kwargs...) = nothing
_logmsg(::Strategy{<:Union{Paper,Live}}, ::Val{:debug}, msg; kwargs...) = @debug msg kwargs...
_logmsg(::Strategy{<:Union{Paper,Live}}, ::Val{:info}, msg; kwargs...) = @info msg kwargs...
_logmsg(::Strategy{<:Union{Paper,Live}}, ::Val{:warn}, msg; kwargs...) = @warn msg kwargs...
_logmsg(::Strategy{<:Union{Paper,Live}}, ::Val{:error}, msg; kwargs...) = @error msg kwargs...

macro ldebug(msg, args...)
    ex = quote
        $(_logmsg)(s, Val(:debug), $msg; $(args...))
    end
    esc(ex)
end

macro linfo(msg, args...)
    ex = quote
        $(_logmsg)(s, Val(:info), $msg; $(args...))
    end
    esc(ex)
end

macro lwarn(msg, args...)
    ex = quote
        $(_logmsg)(s, Val(:warn), $msg; $(args...))
    end
    esc(ex)
end

macro lerror(msg, args...)
    ex = quote
        $(_logmsg)(s, Val(:error), $msg; $(args...))
    end
    esc(ex)
end

export @ldebug, @linfo, @lwarn, @lerror
