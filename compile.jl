using Pkg: Pkg
# Pkg.activate()
# Pkg.add("PackageCompiler")
# using PackageCompiler

# function docompile(mods, sysimage_path)
#     let tries = Ref(1)
#         try
#             while tries[] < 3
#                 try
#                     create_sysimage(
#                         mods;
#                         sysimage_path,
#                         cpu_target=get(ENV, "JULIA_CPU_TARGET", "znver2"),
#                     )
#                     break
#                 catch e
#                     Base.showerror(stderr, e)
#                     tries[] += 1
#                 end
#             end
#         finally
#             Pkg.activate()
#         end
#     end
# end

# if get(ENV, "JULIA_PRECOMP_PROJ", "") == "PingPong"
#     Pkg.activate("PingPong")
#     Pkg.instantiate()
#     using PingPong # required to load dyn libs
#     docompile(["PingPong"], "/pingpong/PingPong.so")
# else
#     Pkg.activate("IPingPong")
#     Pkg.instantiate()
#     using IPingPong # required to load dyn libs
#     docompile(["IPingPong", "WGLMakie"], "/pingpong/IPingPong.so")
# end

using Pkg: Pkg
using PackageCompiler

function compile(proj_path="user/Load"; comp_dir="Dist", app=false, kwargs...)
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
            proj_path, comp_dir; incremental=true, include_lazy_artifacts=true, kwargs...
        )
    else
        create_sysimage([name]; sysimage_path="./PingPong.so", kwargs...)
    end
end
