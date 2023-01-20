import Pkg

@doc "Recursively resolves all julia projects in a directory."
function recurse_projects(path="."; top = true, doupdate=false)
    path = realpath(path)
    for subpath in readdir(path)
        fullpath = joinpath(path, subpath)
        if endswith(fullpath, "Project.toml")
            projpath = dirname(joinpath(path, fullpath))
            Pkg.activate(projpath)
            Pkg.resolve()
            doupdate && Pkg.update()
        elseif isdir(fullpath)
            if !startswith(fullpath, ".") && !endswith(fullpath, "test")
                recurse_projects(fullpath; top=false)
            end
        end
    end
    top && Pkg.activate(pwd())
end
