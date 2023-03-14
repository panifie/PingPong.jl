using Distributed: @everywhere, workers, addprocs, rmprocs, RemoteChannel

const workers_setup = Ref(0)

@doc "Instantiate new workers if the current number mismatches the requested one."
function _instantiate_workers(mod; force=false, num=4)
    if workers_setup[] !== num || force
        length(workers()) > 1 && rmprocs(workers())

        m = _find_module(mod)
        exeflags = "--project=$(pkgdir(m))"
        addprocs(num; exeflags)

        @info "Instantiating $(length(workers())) workers."
        # Instantiate one at a time
        # to avoid possible duplicate parallel instantiations of CondaPkg
        c = RemoteChannel(1)
        put!(c, true)
        @eval @everywhere begin
            take!($c)
            using $mod
            put!($c, true)
        end
        workers_setup[] = num
    end
end
