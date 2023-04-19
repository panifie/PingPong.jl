using Test

test_aqua() = @testset "aqua" begin
    pkg = PingPong
    # Aqua.test_ambiguities(pkg) skip=true
    # Aqua.test_stale_deps(pkg; ignore=[:Aqua]) skip=true
    Aqua.test_unbound_args(pkg)
    Aqua.test_project_toml_formatting(pkg)
    Aqua.test_undefined_exports(pkg)
end
