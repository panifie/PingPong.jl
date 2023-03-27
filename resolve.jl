using Pkg: Pkg

function recurse_projects(
    f, path="."; top=true, exclude=("test", "docs", "deps"), kwargs...
)
    path = realpath(path)
    for subpath in readdir(path)
        fullpath = joinpath(path, subpath)
        if endswith(fullpath, "Project.toml")
            f(path, fullpath; kwargs...)
        elseif isdir(fullpath)
            if !startswith(fullpath, ".") && all((!endswith(fullpath, e) for e in exclude))
                recurse_projects(f, fullpath; top=false, kwargs...)
            end
        end
    end
    top && Pkg.activate(pwd())
end

function _update_project(path, fullpath; precomp, inst, doupdate)
    projpath = dirname(joinpath(path, fullpath))
    Pkg.activate(projpath)
    Pkg.resolve()
    doupdate && begin
        Pkg.offline(false)
        Pkg.update()
        Pkg.offline(true)
    end
    precomp && Pkg.precompile()
    inst && Pkg.instantiate()
end

function update_projects(path="."; doupdate=false, inst=false, precomp=false)
    recurse_projects(_update_project, path; doupdate, inst, precomp)
end

function _project_name!(path, fullpath; projects)
    projpath = dirname(joinpath(path, fullpath))
    Pkg.activate(projpath)
    name = Pkg.project().name
    isnothing(name) || push!(projects, name)
end

function projects_name(path=".")
    projects = Set{String}()
    recurse_projects(_project_name!, path; projects)
    projects
end

function purge_compilecache(path=".")
    names = projects_name(path)
    compiled = joinpath(
        homedir(), ".julia", "compiled", "v$(VERSION.major).$(VERSION.minor)"
    )
    for name in names
        pkg_path = joinpath(compiled, name)
        if isdir(pkg_path)
            rm(pkg_path; recursive=true)
        end
    end
end
