using Pkg: Pkg
Pkg.add("PackageCompiler")
using PackageCompiler
Pkg.activate("IPingPong")
let tries = Ref(1)
    try
        while tries[] < 3
            try
                create_sysimage(
                    ["IPingPong", "WGLMakie"]; sysimage_path="/pingpong/PingPong.so"
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
