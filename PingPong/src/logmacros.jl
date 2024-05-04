using Engine.Executors: Strategy
using Engine.Strategies: SimStrategy
using Engine.LiveMode: RTStrategy

_logmsg(::SimStrategy, val, msg; kwargs...) = nothing
function _logmsg(::RTStrategy, ::Val{:debug}, msg; kwargs...)
    @debug msg kwargs...
end
_logmsg(::RTStrategy, ::Val{:info}, msg; kwargs...) = @info msg kwargs...
_logmsg(::RTStrategy, ::Val{:warn}, msg; kwargs...) = @warn msg kwargs...
function _logmsg(::RTStrategy, ::Val{:error}, msg; kwargs...)
    @error msg kwargs...
end

isliveorpaper(::RTStrategy) = true
isliveorpaper(::SimStrategy) = false

@doc "Log macro for logging debug messages only in `Paper` and `Live` mode."
macro ldebug(args...)
    ex = quote
        if $isliveorpaper(s)
            @debug $(args...)
        end
    end
    esc(ex)
end

@doc "Log macro for logging info messages only in `Paper` and `Live` mode."
macro linfo(args...)
    ex = quote
        if $isliveorpaper(s)
            @info $(args...)
        end
    end
    esc(ex)
end

@doc "Log macro for logging warning messages only in `Paper` and `Live` mode."
macro lwarn(args...)
    ex = quote
        if $isliveorpaper(s)
            @warn $(args...)
        end
    end
    esc(ex)
end

@doc "Log macro for logging error messages only in `Paper` and `Live` mode."
macro lerror(args...)
    ex = quote
        if $isliveorpaper(s)
            @error $(args...)
        end
    end
    esc(ex)
end

export @ldebug, @linfo, @lwarn, @lerror
