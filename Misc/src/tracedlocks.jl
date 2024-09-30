# Import necessary functions from Base
import Base: lock, unlock, trylock, islocked, getproperty
using Base.Threads: ReentrantLock, current_task
using .Lang: @caller

# Define a new lock type for deadlock detection
@kwdef struct TracedLock <: AbstractLock
    lock = ReentrantLock()
end

const SafeLock = if @something tryparse(Bool, get(ENV, "PINGPONG_TRACE_LOCKS", "0")) false
    TracedLock
else
    ReentrantLock
end

# Lock tracking data structures
const lock_graph = Dict{Task, Set{Task}}()  # Task -> Set of tasks it waits for
const held_locks = Dict{Task, Dict{TracedLock, Int}}()  # Task -> Locks it holds and their lock counts
const waiting_for_lock = Dict{Task, TracedLock}()  # Task -> The lock it is waiting for
const lock_to_task = Dict{TracedLock, Task}()  # TracedLock -> Task that holds it
const lock_errors = Dict{Task,Any}()

# Helper function to detect cycles in the task dependency graph
function detect_deadlock(task::Task, visited::Set{Task}=Set{Task}())
    if task in visited
        return true  # Deadlock detected (cycle in graph)
    end
    push!(visited, task)
    if haskey(lock_graph, task)
        for dep in lock_graph[task]
            if detect_deadlock(dep, visited)
                return true
            end
        end
    end
    pop!(visited)
    return false
end

# Function to acquire a TracedLock
function lock(l::TracedLock)
    current = current_task()

    # Check if the lock is already held by another task
    if haskey(lock_to_task, l)
        holder_task = lock_to_task[l]
        if holder_task != current
            # Track dependency current -> holder_task
            if !haskey(lock_graph, current)
                lock_graph[current] = Set()
            end
            push!(lock_graph[current], holder_task)

            # Check for a deadlock by detecting a cycle
            if detect_deadlock(current)
                from = @caller(10)
                lock_errors[current] = string(now(), "@", from)
                error("Deadlock detected involving task $(objectid(current))")
            end

            # Record that current is waiting for lock `l`
            waiting_for_lock[current] = l
        end
    end

    # Acquire the lock (standard behavior)
    lock(l.lock)
    sto = task_local_storage()
    sto[:caller] = @caller(10)

    # Mark the lock as held by the current task
    lock_to_task[l] = current
    if !haskey(held_locks, current)
        held_locks[current] = Dict{TracedLock, Int}()
    end

    # Increment the reentrant lock counter
    held_locks[current][l] = get(held_locks[current], l, 0) + 1

    # Clear the waiting status and dependencies for the current task
    delete!(waiting_for_lock, current)
    if haskey(lock_graph, current)
        empty!(lock_graph[current])
    end
end

# Function to release a TracedLock
function unlock(l::TracedLock)
    current = current_task()

    # Ensure the current task holds the lock
    if !haskey(held_locks, current) || !(l in keys(held_locks[current]))
        from = @caller(10)
        lock_errors[current] = string(now(), "@", from)
        error("Task $(objectid(current)) tried to release a lock it doesn't hold")
    end

    # Decrement the reentrant lock counter
    held_locks[current][l] -= 1

    # If the task has unlocked it the same number of times it locked it, release it
    if held_locks[current][l] == 0

        # Remove the lock from the tracking dictionaries
        delete!(held_locks[current], l)
        delete!(lock_to_task, l)

        # Clean up if the task holds no other locks
        if isempty(held_locks[current])
            delete!(held_locks, current)
        end
    end
    unlock(l.lock)
end

# Function to try to acquire a TracedLock (non-blocking)
function trylock(l::TracedLock)
    current = current_task()

    # Try to acquire the lock (non-blocking)
    success = trylock(l.lock)

    if success
        # If successful, proceed as usual
        lock_to_task[l] = current
        if !haskey(held_locks, current)
            held_locks[current] = Dict{TracedLock, Int}()
        end

        # Increment the reentrant lock counter
        held_locks[current][l] = get(held_locks[current], l, 0) + 1

        # Clear waiting status and dependencies
        delete!(waiting_for_lock, current)
        if haskey(lock_graph, current)
            empty!(lock_graph[current])
        end
    end
    return success
end

function islocked(l::TracedLock)
    islocked(l.lock)
end

function getproperty(l::TracedLock, k::Symbol)
    l = getfield(l, :lock)
    if k == :lock
        l
    else
        getfield(l, k)
    end
end

export SafeLock
