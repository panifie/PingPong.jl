using PythonCall: Py, pynew, pyimport, pycopy!, pyisnull, @pyexec, pybuiltins

const pyaio = pynew()
const pyuv = pynew()
const pythreads = pynew()
const pyrunner = pynew()
const pyrunner_thread = pynew()
const pyloop = pynew()

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
    @assert pyisnull(pyrunner_thread)
    pycopy!(pyrunner, pyaio.Runner(; loop_factory=pyuv.new_event_loop))
    pycopy!(pyrunner_thread, pythreads.Thread(; target=pyrunner.run, args=[async_main_func()()]))
    # We need to set the thread as daemon, to stop it automatically when exiting the main (julia) thread.
    pyrunner_thread.daemon = pybuiltins.True
    pyrunner_thread.start()
    pycopy!(pyloop, pyrunner.get_loop())
end

function pytask(f::Py, args...; kwargs...)
    fut = pyaio.run_coroutine_threadsafe(f(args...; kwargs...), pyloop)
    @async begin
        while !Bool(fut.done())
            sleep(0.01)
        end
        fut.result()
    end
end

pyfetch(f::Py, args...; kwargs...) = fetch(pytask(f, args...; kwargs...))

@doc "Main async loop function, sleeps indefinitely and closes loop on exception."
function async_main_func()
    g = pydict()
    pyexec("""
        import asyncio
        from math import inf
        async def main():
            try:
                await asyncio.sleep(inf)
            finally:
                asyncio.get_running_loop().stop()
        """,
        g,
    )
    g["main"]
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

export pytask, pyfetch
