using Pkg: Pkg
Pkg.add("PackageCompiler")
using PackageCompiler
Pkg.activate("IPingPong")
tries = 1
try
    while tries < 3
        try
            create_sysimage(
                ["IPingPong", "WGLMakie"]; sysimage_path="/pingpong/PingPong.so"
            )
        catch
        end
    end
finally
    Pkg.activate()
end
