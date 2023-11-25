@doc "Get the list of errors that occurred during the execution of a watcher."
errors(w::Watcher) = _errors(w)
@doc """ Stores an error to the watcher log journal.

$(TYPEDSIGNATURES)

This function logs an error that occurred during the execution of a watcher. The error is stored in the watcher's log journal. If the watcher has a logfile attribute, the error is written to the logfile. Otherwise, the error is pushed to the watcher's error buffer.
"""
function logerror(w::Watcher, e, bt=[])
    if hasattr(w, :logfile)
        file = attr(w, :logfile)
        open(file, "a") do f
            println(f, string(Dates.now()))
            Base.showerror(f, e)
            isempty(bt) || Base.show_backtrace(f, bt)
        end
    else
        push!(_errors(w), (e, bt))
    end
    e
end
@doc "Get the last logged watcher error."
lasterror(w::Watcher) = isempty(w._exec.errors) ? nothing : last(w._exec.errors)
@doc "Get the last logged watcher error of type `t`."
lasterror(t::Type, w::Watcher) = findlast(e -> e isa t, w._exec.errors)
@doc "Get all logged watcher errors of type `t`."
allerror(t::Type, w::Watcher) = filter(e -> e[1] isa t, w._exec.errors)
@doc """ Display the backtrace of the last logged watcher error.

$(TYPEDSIGNATURES)

This function retrieves and displays the backtrace of the last logged error for a given watcher. If no errors have been logged for the watcher, it does nothing.
"""
function showtrace(w::Watcher, rev_idx=0)
    if !isempty(w._exec.errors)
        e = errors(w)[end - rev_idx]
        Base.show_backtrace(stderr, e[2])
        println("\n")
        Base.showerror(stderr, e[1])
    end
end
@doc """ Logs an error that occurred during the execution of an expression.

$(TYPEDSIGNATURES)

This macro tries to execute the provided expression and logs any error that occurs during its execution. The error is logged to the watcher's log journal. If the watcher has a logfile attribute, the error is written to the logfile. Otherwise, the error is pushed to the watcher's error buffer.
"""
macro logerror(w, expr)
    quote
        try
            $(esc(expr))
        catch e
            logerror($(esc(w)), e, stacktrace(catch_backtrace()))
        end
    end
end

export logerror, @logerror
