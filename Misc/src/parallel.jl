using Distributed: @everywhere, workers, addprocs, rmprocs, RemoteChannel

const workers_setup = Ref(0)

@doc """Instantiates worker processes for a given module.

$(TYPEDSIGNATURES)

This function takes a module `mod` and optionally a boolean `force` and an integer `num`. It spawns `num` worker processes for `mod`. If `force` is true, it first kills any existing worker processes for `mod`.

"""
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
