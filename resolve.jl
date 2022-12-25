import Pkg

@doc "Recursively resolves all julia projects in a directory."
function recurse_projects(path=".")
    path = realpath(path)
    for subpath in readdir(path)
        fullpath = joinpath(path, subpath)
        if endswith(fullpath, "Project.toml")
            projpath = dirname(joinpath(path, fullpath))
            Pkg.activate(projpath)
            Pkg.resolve()
        elseif isdir(fullpath)
            if !startswith(fullpath, ".") && !endswith(fullpath, "test")
                recurse_projects(fullpath)
            end
        end
    end
end
