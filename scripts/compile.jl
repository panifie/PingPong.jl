using Pkg: Pkg

Pkg.activate(joinpath("user", "Load"))
Pkg.add("PackageCompiler")
using PackageCompiler

function compile(proj_path="user/Load"; comp_dir="Dist", cpu_target="generic", app=false, kwargs...)
    @assert ispath(proj_path)
    Pkg.activate(proj_path)
    ENV["JULIA_PROJECT"] = dirname(Base.active_project())
    @assert !isempty(get(ENV, "JULIA_FULL_PRECOMP", ""))
    ENV["JULIA_PRECOMP"] = ENV["JULIA_FULL_PRECOMP"]
    name = let dir = dirname(proj_path)
        if endswith(dir, "src")
            basename(dirname(dir))
        else
            basename(proj_path)
        end
    end
    if app
        create_app(
            proj_path, comp_dir; cpu_target, incremental=true, include_lazy_artifacts=true, kwargs...
        )
    else
        create_sysimage([name]; cpu_target, sysimage_path="./PingPong.so", kwargs...)
    end
end
