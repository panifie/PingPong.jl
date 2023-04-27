using PythonCall:
    Py, pynew, pydict, pyimport, pyexec, pycopy!, pyisnull, pybuiltins, pyconvert

@kwdef struct PythonAsync
    pyaio::Py = pynew()
    pyuv::Py = pynew()
    pythreads::Py = pynew()
    pyrunner::Py = pynew()
    pyrunner_thread::Py = pynew()
    pyloop::Py = pynew()
    pycoro_type::Py = pynew()
end

const gpa = PythonAsync()

function isinitialized_async(pa::PythonAsync)
    !pyisnull(pa.pyaio)
end

function Base.copyto!(pa_to::PythonAsync, pa_from::PythonAsync)
    if pyisnull(pa_to.pyaio) && !pyisnull(pa_from.pyaio)
        for f in fieldnames(PythonAsync)
            pycopy!(getfield(pa_to, f), getfield(pa_from, f))
        end
        true
    else
        false
    end
end

function _async_init(pa::PythonAsync)
    isinitialized_async(pa) && return nothing
    copyto!(pa, gpa) && return nothing
    if pyisnull(pa.pyaio)
        pycopy!(pa.pyaio, pyimport("asyncio"))
        pycopy!(pa.pyuv, pyimport("uvloop"))
        pycopy!(pa.pythreads, pyimport("threading"))
        py_start_loop(pa)
        if pyisnull(gpa.pyaio)
            for f in fieldnames(PythonAsync)
                pycopy!(getfield(gpa, f), getfield(pa, f))
            end
        end
    end
    copyto!(gpa, pa)
    @assert !pyisnull(gpa.pyaio)
end

function py_start_loop(pa::PythonAsync)
    pyaio = pa.pyaio
    pyuv = pa.pyuv
    pythreads = pa.pythreads
    pyrunner = pa.pyrunner
    pyrunner_thread = pa.pyrunner_thread
    pyloop = pa.pyloop
    pycoro_type = pa.pycoro_type

    @assert !pyisnull(pyaio)
    @assert !pyisnull(pythreads)
    @assert pyisnull(pyloop) || !Bool(pyloop.is_running())
    @assert pyisnull(pyrunner_thread) || !Bool(pyrunner_thread.is_alive())

    pycopy!(pycoro_type, pyimport("types").CoroutineType)
    pycopy!(pyrunner, pyaio.Runner(; loop_factory=pyuv.new_event_loop))
    pycopy!(
        pyrunner_thread, pythreads.Thread(; target=pyrunner.run, args=[async_main_func()()])
    )
    # We need to set the thread as daemon, to stop it automatically when exiting the main (julia) thread.
    pyrunner_thread.daemon = pybuiltins.True
    pyrunner_thread.start()
    pycopy!(pyloop, pyrunner.get_loop())
end

# FIXME: This doesn't work if we pass `args...; kwargs...`
macro pytask(code)
    @assert code.head == :call
    Expr(:call, :pytask, esc(code.args[1]), esc.(code.args[2:end])...)
end

# FIXME: This doesn't work if we pass `args...; kwargs...`
macro pyfetch(code)
    @assert code.head == :call
    Expr(:call, :pyfetch, esc(code.args[1]), esc.(code.args[2:end])...)
end

function pyschedule(coro::Py)
    gpa.pyaio.run_coroutine_threadsafe(coro, gpa.pyloop)
end

pywait_fut(fut::Py) = begin
    while !Bool(fut.done())
        sleep(0.01)
    end
end
pytask(coro::Py, ::Val{:coro}) = begin
    @async let fut = pyschedule(coro)
        pywait_fut(fut)
        fut.result()
    end
end
pytask(coro::Py, ::Val{:try}) = begin
    @async try
        fut = pyschedule(coro)
        pywait_fut(fut)
        fut.result()
    catch e
        e
    end
end
pytask(f::Py, args...; kwargs...) = pytask(f(args...; kwargs...), Val(:coro))
function pytask(f::Py, ::Val{:try}, args...; kwargs...)
    pytask(f(args...; kwargs...), Val(:try))
end
pyfetch(f::Py, args...; kwargs...) = fetch(pytask(f, args...; kwargs...))
function pyfetch(f::Py, ::Val{:try}, args...; kwargs...)
    fetch(pytask(f, Val(:try), args...; kwargs...))
end

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

@doc "Main async loop function, sleeps indefinitely and closes loop on exception."
function async_main_func()
    code = """
    global asyncio, inf
    import asyncio
    from math import inf
    async def main():
        try:
            await asyncio.sleep(inf)
        finally:
            asyncio.get_running_loop().stop()
    """
    pyexec(NamedTuple{(:main,),Tuple{Py}}, code, pydict()).main
end

# NOTE: untested
# @doc "Raises an exception in a python thread, used to stop async loop."
# function raise_exception()
#     globals = pydict()
#     globals["t"] = gpa.pyrunner_thread
#     code = """
#     from threading import Thread
#     from asyncio import CancelledError
#     from ctypes import c_long, c_ulong, py_object, pythonapi
#     try:
#         pythonapi.PyThreadState_SetAsyncExc(c_long(t.ident), py_object(CancelledError))
#     except:
#         import traceback
#         traceback.print_exc()
#     import sys
#     sys.stdout.flush()
#     """
#     pyexec(code, globals)
# end

export pytask, pyfetch, @pytask, @pyfetch
