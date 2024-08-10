# HACK: remove openssl from PythonCall CondaPkg.toml file
# because version rewrite does not happen in precompiled sys images
using Python
using TOML
toml_path = joinpath(dirname(dirname(pathof(Python.PythonCall))), "CondaPkg.toml")
config = TOML.parsefile(toml_path)
delete!(config, "openssl")
delete!(get(config, "deps", Dict()), "openssl")
run(`chmod 777 $toml_path`)
open(toml_path, "w") do f
    TOML.print(f, config)
end
