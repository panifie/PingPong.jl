import Pkg
Pkg.add("PackageCompiler")
using PackageCompiler
Pkg.activate("IPingPong")
tries = 1
while tries < 3
    create_sysimage(["IPingPong", "WGLMakie"], sysimage_path="/pingpong/PingPong.so")
end
