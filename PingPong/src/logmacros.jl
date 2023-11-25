using Engine.Executors: Strategy

_logmsg(::Strategy{Sim}, val, msg; kwargs...) = nothing
_logmsg(::Strategy{<:Union{Paper,Live}}, ::Val{:debug}, msg; kwargs...) = @debug msg kwargs...
_logmsg(::Strategy{<:Union{Paper,Live}}, ::Val{:info}, msg; kwargs...) = @info msg kwargs...
_logmsg(::Strategy{<:Union{Paper,Live}}, ::Val{:warn}, msg; kwargs...) = @warn msg kwargs...
_logmsg(::Strategy{<:Union{Paper,Live}}, ::Val{:error}, msg; kwargs...) = @error msg kwargs...

@doc "Log macro for logging debug messages only in `Paper` and `Live` mode."
macro ldebug(msg, args...)
    ex = quote
        $(_logmsg)(s, Val(:debug), $msg; $(args...))
    end
    esc(ex)
end

@doc "Log macro for logging info messages only in `Paper` and `Live` mode."
macro linfo(msg, args...)
    ex = quote
        $(_logmsg)(s, Val(:info), $msg; $(args...))
    end
    esc(ex)
end

@doc "Log macro for logging warning messages only in `Paper` and `Live` mode."
macro lwarn(msg, args...)
    ex = quote
        $(_logmsg)(s, Val(:warn), $msg; $(args...))
    end
    esc(ex)
end

@doc "Log macro for logging error messages only in `Paper` and `Live` mode."
macro lerror(msg, args...)
    ex = quote
        $(_logmsg)(s, Val(:error), $msg; $(args...))
    end
    esc(ex)
end

export @ldebug, @linfo, @lwarn, @lerror
