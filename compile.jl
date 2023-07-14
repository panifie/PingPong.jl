using Pkg: Pkg
Pkg.activate()
Pkg.add("PackageCompiler")
using PackageCompiler

function docompile(mods, sysimage_path)
    let tries = Ref(1)
        try
            while tries[] < 3
                try
                    create_sysimage(
                        mods;
                        sysimage_path,
                        cpu_target=get(ENV, "JULIA_CPU_TARGET", "znver2"),
                    )
                    break
                catch e
                    Base.showerror(stderr, e)
                    tries[] += 1
                end
            end
        finally
            Pkg.activate()
        end
    end
end

if get(ENV, "JULIA_PRECOMP_PROJ", "") == "PingPong"
    Pkg.activate("PingPong")
    Pkg.instantiate()
    using PingPong # required to load dyn libs
    docompile(["PingPong"], "/pingpong/PingPong.so")
else
    Pkg.activate("IPingPong")
    Pkg.instantiate()
    using IPingPong # required to load dyn libs
    docompile(["IPingPong", "WGLMakie"], "/pingpong/IPingPong.so")
end
