@doc """ Check if a task is running.

$(TYPEDSIGNATURES)

This function checks if a task (`t`) is running. A task is considered running if it has started and is not yet done.

"""
istaskrunning(t::Task) = istaskstarted(t) && !istaskdone(t)
istaskrunning(t) = false
@doc """ Stops a task if it's running.

$(TYPEDSIGNATURES)

This function attempts to stop a running task `t`. It sets the task's running flag to `false` and notifies any waiting threads if applicable.

"""
stop_task(t::Task) = begin
    t.storage[:running] = false
    if istaskrunning(t)
        try
            let cond = get(t.storage, :notify, nothing)
                isnothing(cond) || safenotify(cond)
            end
            istaskdone(t)
        catch
            @error "Running flag not set on task $t" istaskdone(t) istaskstarted(t)
            false
        end
    else
        true
    end
end

@doc """ Initializes and starts a task with a given state.

$(TYPEDSIGNATURES)

This function initializes a task `t` with a given `state`, schedules the task, and then returns the task.

"""
start_task(t::Task, state) = (init_task(t, state); schedule(t); t)

@doc """ Initializes a task with a given state.

$(TYPEDSIGNATURES)

This function initializes a task `t` with a given `state`. It sets up the task's storage dictionary which includes running flag, state, and a condition variable for notification.

"""
init_task(t::Task, state) = begin
    if isnothing(t.storage)
        sto = t.storage = IdDict{Any,Any}()
    end
    @lget! sto :running true
    @lget! sto :state state
    @lget! sto :notify Base.Threads.Condition()
    t
end
init_task(state) = init_task(current_task, state)

@doc """ Checks if the current task is running.

This function checks if the current task is running by accessing the task's local storage.

!!! warning "Don't use within macros"
    Use the homonymous macro `@istaskrunning()` instead.

"""
istaskrunning() = task_local_storage(:running)
@doc """ Checks if the current task is running (Macro).

Equivalent to `istaskrunning()` but should be used within other macros.
"""
macro istaskrunning()
    quote
        try
            task_local_storage(:running)
        catch
        end
    end
end

@doc """ Used to indicate that a task is still running.

$(FIELDS)
"""
struct TaskFlag
    "The function that indicates that the task is still running (returns a `Bool`)."
    f::Function
end
@doc """ The default task flag

Uses the task local storage to communicate if the task is still running.
"""
TaskFlag() =
    let sto = task_local_storage()
        TaskFlag(() -> sto[:running])
    end
@doc """ Used to send a cancel request to the python coroutine.

The python coroutine will be cancelled if the task `getindex` returns `true`.
The task flag is passed to `pyfetch/pytask` as a tuple.
"""
pycoro_running(flag) = (flag,)
pycoro_running() = pycoro_running(TaskFlag())
Base.getindex(t::TaskFlag) = t.f()
