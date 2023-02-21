using PythonCall: Py, pynew, pyimport, pycopy!, pyisnull, @pyexec, pybuiltins

const pyaio = pynew()
const pyuv = pynew()
const pythreads = pynew()
const pyrunner = pynew()
const pyrunner_thread = pynew()
const pyloop = pynew()
const pyrun = pynew()

function _async_init()
    if pyisnull(pyaio)
        pycopy!(pyaio, pyimport("asyncio"))
        pycopy!(pyuv, pyimport("uvloop"))
        pycopy!(pythreads, pyimport("threading"))
        py_start_loop()
    end
end

function py_start_loop()
    @assert !pyisnull(pyaio)
    @assert !pyisnull(pythreads)
    @assert pyisnull(pyloop) || !Bool(pyloop.is_running())
    @assert pyisnull(pyrunner_thread) || !Bool(pyrunner_thread.is_alive())
    pycopy!(pyrunner, pyaio.Runner(; loop_factory=pyuv.new_event_loop))
    pycopy!(
        pyrunner_thread, pythreads.Thread(; target=pyrunner.run, args=[async_main_func()()])
    )
    # We need to set the thread as daemon, to stop it automatically when exiting the main (julia) thread.
    pyrunner_thread.daemon = pybuiltins.True
    pyrunner_thread.start()
    pycopy!(pyloop, pyrunner.get_loop())
    pycopy!(pyrun, run_with_yield_func())
end

macro pytask(code)
    @assert code.head == :call
    Expr(:call, :pytask, esc(code.args[1]), esc.(code.args[2:end])...)
end

macro pyfetch(code)
    @assert code.head == :call
    Expr(:call, :pyfetch, esc(code.args[1]), esc.(code.args[2:end])...)
end

pytask(f::Py, args...; kwargs...) = @async pyrun(f, args...; kwargs...)
pyfetch(f::Py, args...; kwargs...) = fetch(pytask(f, args...; kwargs...))

@doc "Generates a julia yielding function to run python async coroutines."
function run_with_yield_func()
    @pyexec (pyloop = pyloop) =>
        """
    global asyncio, jl, doyield, myloop
    import asyncio
    from juliacall import Main as jl
    doyield = getattr(jl, "yield")
    myloop = pyloop
    def run(f, *args, **kwargs):
        try:
            fut = asyncio.run_coroutine_threadsafe(f(*args, **kwargs), myloop)
            while not fut.done(): # Can't use running() here because the task is not started right away
                doyield()
            return fut.result()
        except Exception as e:
            return e
    """ => run
end

@doc "Main async loop function, sleeps indefinitely and closes loop on exception."
function async_main_func()
    @pyexec () => """
    global asyncio, inf
    import asyncio
    from math import inf
    async def main():
        try:
            await asyncio.sleep(inf)
        finally:
            asyncio.get_running_loop().stop()
    """ => main
end

@doc "Raises an exception in a python thread, used to stop async loop."
function raise_exception()
    @pyexec (t = pyrunner_thread) => """
    from threading import Thread
    from asyncio import CancelledError
    from ctypes import c_long, c_ulong, py_object, pythonapi
    try:
        pythonapi.PyThreadState_SetAsyncExc(c_long(t.ident), py_object(CancelledError))
    except:
        import traceback
        traceback.print_exc()
    import sys
    sys.stdout.flush()
    """
end

export pytask, pyfetch, @pytask, @pyfetch
