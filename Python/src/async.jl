using PythonCall: Py, pynew, pyimport, pycopy!, pyisnull

const pyaio = pynew()
const pythreads = pynew()
const pyloop = pynew()
const pyloop_thread = pynew()

function _async_init()
    if pyisnull(pyaio)
        pycopy!(pyaio, pyimport("asyncio"))
        pycopy!(pythreads, pyimport("threading"))
        pycopy!(pyloop, pyaio.new_event_loop())
        py_start_loop()
    end
end

function py_start_loop()
    @assert !pyisnull(pyaio)
    @assert !pyisnull(pythreads)
    @assert !pyisnull(pyloop)
    @assert pyisnull(pyloop_thread)
    pycopy!(pyloop_thread, pythreads.Thread(; target=pyloop.run_forever))
    pyloop_thread.start()
end

function pyasync_run(f::Py, args...; kwargs...)
    fut = pyaio.run_coroutine_threadsafe(f(args...; kwargs...), pyloop)
    @async begin
        while !Bool(fut.done())
            sleep(0.01)
        end
        fut.result()
    end
end

export pyasync_run
