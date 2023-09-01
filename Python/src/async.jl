using PythonCall:
    Py, pynew, pydict, pyimport, pyexec, pycopy!, pyisnull, pybuiltins, pyconvert, pyisTrue
using Dates: Period, Second
using ThreadPools: @tspawnat
using Mocking: @mock, Mocking

"""
    PythonAsync(;pyaio::Py = pynew(), pyuv::Py = pynew(), pythreads::Py = pynew(), pyrunner::Py = pynew(), pyloop::Py = pynew(), pycoro_type::Py = pynew(), task::Ref{Task} = Ref{Task}())

A structure that holds references to the Python asynchronous objects and state.
"""
@kwdef struct PythonAsync
    pyaio::Py = pynew()
    pythreads::Py = pynew()
    pyloop::Py = pynew()
    pycoro_type::Py = pynew()
    task::Ref{Task} = Ref{Task}()
    task_running::Ref{Bool} = Ref(false)
end

isdefined(@__MODULE__, :gpa) || @eval const gpa = PythonAsync()

"""
    isinitialized_async(pa::PythonAsync)

Checks if python async state (event loop) is initialized.
"""
function isinitialized_async(pa::PythonAsync)
    !pyisnull(pa.pyaio)
end

"""
    copyto!(pa_to::PythonAsync, pa_from::PythonAsync)

Copies a python async structures.
"""
function Base.copyto!(pa_to::PythonAsync, pa_from::PythonAsync)
    if pyisnull(pa_to.pyaio) && !pyisnull(pa_from.pyaio)
        for f in fieldnames(PythonAsync)
            let v = getfield(pa_from, f)
                if v isa Py
                    pycopy!(getfield(pa_to, f), v)
                elseif f == :task
                    isassigned(v) && (pa_to.task[] = v[])
                elseif f == :task_running
                    pa_to.task_running[] = v[]
                else
                    error()
                end
            end
        end
        true
    else
        false
    end
end

"""
    _async_init(pa::PythonAsync)

Initialized a =PythonAsync= structure (which holds a reference to the event loop.)
"""
function _async_init(pa::PythonAsync)
    isinitialized_async(pa) && return nothing
    copyto!(pa, gpa) && return nothing
    if pyisnull(pa.pyaio)
        pycopy!(pa.pyaio, pyimport("asyncio"))
        pycopy!(pa.pythreads, pyimport("threading"))
        py_start_loop(pa)
        if pyisnull(gpa.pyaio)
            for f in fieldnames(PythonAsync)
                let v = getfield(gpa, f)
                    if v isa Py
                        pycopy!(v, getfield(pa, f))
                    elseif f == :task
                        isassigned(pa.task) && (v[] = pa.task[])
                    elseif f == :task_runnig
                        v[] = pa.task_running[]
                    else
                        error()
                    end
                end
            end
        end
    end
    copyto!(gpa, pa)
    @assert !pyisnull(gpa.pyaio)
end

"""
    py_start_loop(pa::PythonAsync)

Starts a python event loop, updating =pa=.
"""
function py_start_loop(pa::PythonAsync=gpa)
    pyaio = pa.pyaio
    pyloop = pa.pyloop
    pycoro_type = pa.pycoro_type

    @assert !pyisnull(pyaio)
    @assert pyisnull(pyloop) ||
        pyisnone(pyloop) ||
        !pyisTrue(pyloop.is_running()) ||
        (isassigned(pa.task) && istaskdone(pa.task[]))

    pyisnull(pycoro_type) && pycopy!(pycoro_type, pyimport("types").CoroutineType)
    @assert !isassigned(pa.task) || istaskdone(pa.task[])
    pa.task[] = @async try
        gpa.task_running[] = true
        async_start_runner()()
    catch e
        @debug e
    finally
        gpa.task_running[] = false
        pyisnull(pyloop) || pyloop.stop()
    end

    atexit(pyloop_stop_fn(pa))
end

function py_stop_loop(pa::PythonAsync=gpa)
    pa.task_running[] = false
    try
        wait(pa.task[])
    catch
    end
end

"""
    pyloop_stop_fn(pa)

Generates a function that terminates the python even loop.
"""
function pyloop_stop_fn(pa)
    fn() = begin
        !isassigned(pa.task) || istaskdone(pa.task[]) && return nothing
        pa.task_running[] = false
        pyisnull(pa.pyloop) || pa.pyloop.stop()
        try
            wait(pa.task[])
        catch
        end
    end
    fn
end

# FIXME: This doesn't work if we pass =args...; kwargs...=
macro pytask(code)
    @assert code.head == :call
    Expr(:call, :pytask, esc(code.args[1]), esc.(code.args[2:end])...)
end

# FIXME: This doesn't work if we pass =args...; kwargs...`
macro pyfetch(code)
    @assert code.head == :call
    Expr(:call, :pyfetch, esc(code.args[1]), :(Val(:fut)), esc.(code.args[2:end])...)
end

"""
    pyschedule(coro::Py)

Schedules a Python coroutine to run on the event loop.
"""
function pyschedule(coro::Py)
    if pyisinstance(coro, Python.gpa.pycoro_type)
        # gpa.pyaio.run_coroutine_threadsafe(coro, gpa.pyloop)
        gpa.pyloop.create_task(coro)
    end
end

"""
    _isfutdone(fut::Py)

Checks if a Python future is done.
"""
_isfutdone(fut::Py) = pyisnull(fut) || let v = fut.done()
    pyisTrue(v)
end

"""
    pywait_fut(fut::Py)

Waits for a Python future to be done.
"""
pywait_fut(fut::Py) = begin
    while !_isfutdone(fut)
        sleep(0.01)
    end
end

pywait_fut(fut::Py, running) = begin
    while !_isfutdone(fut)
        running[] || begin
            try
                pycancel(fut)
            catch
            end
            break
        end
        sleep(0.01)
    end
end

"""
    pytask(coro::Py, ::Val{:coro})

Creates a Julia task from a Python coroutine and runs it asynchronously.
"""
function pytask(coro::Py, ::Val{:coro}; coro_running=())
    let fut = pyschedule(coro)
        @async begin
            pywait_fut(fut, coro_running...)
            fut.result()
        end
    end
end

"""
    pytask(coro::Py, ::Val{:fut})::Tuple{Py,Union{Py,Task}}

Creates a Julia task from a Python coroutine and returns the Python future and the Julia task.
"""
pytask(coro::Py, ::Val{:fut}; coro_running=())::Tuple{Py,Union{Py,Task}} = begin
    fut = pyschedule(coro)
    (fut, @async if _isfutdone(fut)
        fut.result()
    else
        (pywait_fut(fut, coro_running...); fut.result())
    end)
end

"""
    pytask(f::Py, args...; kwargs...)

Creates a Julia task from a Python function call and runs it asynchronously.
"""
function pytask(f::Py, args...; coro_running=(), kwargs...)
    pytask(f(args...; kwargs...), Val(:coro); coro_running)
end

"""
    pytask(f::Py, ::Val{:fut}, args...; kwargs...)

Creates a Julia task from a Python function call and returns the Python future and the Julia task.
"""
function pytask(f::Py, ::Val{:sched}, args...; coro_running=(), kwargs...)
    pytask(f(args...; kwargs...), Val(:fut); coro_running)
end

"""
    pycancel(fut::Py)

Cancels a Python future.
"""
pycancel(fut::Py) = pyisnull(fut) || !pyisnull(gpa.pyloop.call_soon_threadsafe(fut.cancel))

"""
    pyfetch(f::Py, args...; kwargs...)

Fetches the result of a Python function call synchronously.
"""
function _pyfetch(f::Py, args...; coro_running=(), kwargs...)
    let (fut, task) = pytask(f(args...; kwargs...), Val(:fut); coro_running)
        try
            fetch(task)
        catch e
            if e isa TaskFailedException
                task.result
            else
                istaskdone(task) || (pycancel(fut); wait(task))
                rethrow(e)
            end
        end
    end
end

"""
    pyfetch(f::Py, ::Val{:try}, args...; kwargs...)

Fetches the result of a Python function call synchronously and returns an exception if any.
"""
function _pyfetch(f::Py, ::Val{:try}, args...; coro_running=(), kwargs...)
    try
        fut, task = pytask(f, Val(:sched), args...; coro_running, kwargs...)
        try
            fetch(task)
        catch e
            if e isa TaskFailedException
                task.result
            else
                istaskdone(task) || (pycancel(fut); wait(task))
                rethrow(e)
            end
        end
    catch e
        e
    end
end

"""
    pyfetch(f::Function, args...; kwargs...)

Fetches the result of a Julia function call synchronously.
"""
function _pyfetch(f::Function, args...; coro_running=(), kwargs...)
    fetch(@async(f(args...; kwargs...)))
end
_mockable_pyfetch(args...; kwargs...) = _pyfetch(args...; kwargs...)
pyfetch(args...; kwargs...) = @mock _mockable_pyfetch(args...; kwargs...)

"""
    pyfetch_timeout(
        f1::Py, f2::Union{Function,Py}, timeout::Period, args...; kwargs...
)

Fetches the result of a Python function call synchronously with a timeout. If the timeout is reached,
it calls another function and returns its result.
"""
function _pyfetch_timeout(
    f1::Py, f2::Union{Function,Py}, timeout::Period, args...; coro_running=(), kwargs...
)
    coro = gpa.pyaio.wait_for(f1(args...; kwargs...); timeout=Second(timeout).value)
    (fut, task) = pytask(coro, Val(:fut); coro_running)
    try
        fetch(task)
    catch e
        if e isa TaskFailedException
            pyfetch(f2, args...; coro_running, kwargs...)
        else
            istaskdone(task) || (pycancel(fut); wait(task))
            rethrow(e)
        end
    end
end

pyfetch_timeout(args...; kwargs...) = @mock _pyfetch_timeout(args...; kwargs...)

# function isrunning_func(running)
#     @pyexec (running) => """
#     global jl, jlrunning
#     import juliacall as jl
#     jlrunning = running
#     def isrunning(fut):
#         if fut.done():
#             jlrunning[0] = False
#     """ => isrunning
# end

# @doc "Main async loop function, sleeps indefinitely and closes loop on exception."
# function async_main_func()
#     code = """
#     global asyncio, inf
#     import asyncio
#     from math import inf
#     async def main():
#         try:
#             await asyncio.sleep(inf)
#         finally:
#             asyncio.get_running_loop().stop()
#     """
#     pyexec(NamedTuple{(:main,),Tuple{Py}}, code, pydict()).main
# end

_pyisrunning() = gpa.task_running[]

_set_loop(loop) = pycopy!(gpa.pyloop, loop)

function async_start_runner()
    code = """
    global asyncio, inf, juliacall, Main, jlyield, uvloop
    import asyncio
    import juliacall
    import uvloop
    from math import inf
    from juliacall import Main
    jlyield = getattr(Main, "yield")
    jlsleep = getattr(Main, "sleep")
    running = getattr(Main, "Python")._pyisrunning
    set_loop = getattr(Main, "Python")._set_loop
    pysleep = asyncio.sleep
    async def main():
        set_loop(asyncio.get_running_loop())
        try:
            while running():
                try:
                    while running():
                        await pysleep(1e-3)
                        jlsleep(1e-1)
                except:
                    await pysleep(1e-1)
                    pass
        finally:
            asyncio.get_running_loop().stop()
    """
    # main_func = pyexec(NamedTuple{(:main,),Tuple{Py}}, code, pydict()).main
    globs = pydict()
    pyexec(NamedTuple{(:main,),Tuple{Py}}, code, globs)
    code = """
    global asyncio, inf, juliacall, Main, jlyield, uvloop
    import asyncio, uvloop
    def start():
        with asyncio.Runner(loop_factory=uvloop.new_event_loop) as runner:
            runner.run(main())
    """
    pyexec(NamedTuple{(:start,),Tuple{Py}}, code, globs).start
end

export pytask, pyfetch, pycancel, @pytask, @pyfetch, pyfetch_timeout
