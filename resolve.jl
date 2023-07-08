using Pkg: Pkg

function recurse_projects(
    f, path="."; io=stdout, top=true, exclude=("test", "docs", "deps", "user"), kwargs...
)
    path = realpath(path)
    @sync for subpath in readdir(path)
        fullpath = joinpath(path, subpath)
        if endswith(fullpath, "Project.toml")
            @async f(path, fullpath; io, kwargs...)
        elseif isdir(fullpath)
            if !startswith(fullpath, ".") && all((!endswith(fullpath, e) for e in exclude))
                recurse_projects(f, fullpath; io, top=false, kwargs...)
            end
        end
    end
    top && Pkg.activate(pwd())
end

function _update_project(path, fullpath; precomp, inst, doupdate, io=stdout)
    projpath = dirname(joinpath(path, fullpath))
    Pkg.activate(projpath; io)
    Pkg.resolve(; io)
    doupdate && begin
        Pkg.offline(false)
        Pkg.update()
        Pkg.offline(true)
    end
    precomp && Pkg.precompile(; io)
    inst && Pkg.instantiate(; io)
end

function update_projects(path="."; io=stdout, doupdate=false, inst=false, precomp=false)
    recurse_projects(_update_project, path; io, doupdate, inst, precomp)
end

function _project_name!(path, fullpath; io, projects)
    projpath = dirname(joinpath(path, fullpath))
    Pkg.activate(projpath; io)
    name = Pkg.project().name
    isnothing(name) || push!(projects, name)
end

function projects_name(path="."; io=stdout)
    projects = Set{String}()
    recurse_projects(_project_name!, path; io, projects)
    projects
end

function purge_compilecache(path="."; io=stdout)
    names = projects_name(path; io)
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
