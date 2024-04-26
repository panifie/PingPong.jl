using Pkg: Pkg

function recurse_projects(
    f,
    path=".";
    io=stdout,
    top=true,
    exclude=("test", "docs", "deps", "user", ".conda", ".CondaPkg", ".git"),
    top_proj=Base.active_project(),
    kwargs...,
)
    path = realpath(path)
    @sync for subpath in readdir(path)
        fullpath = joinpath(path, subpath)
        if endswith(fullpath, "Project.toml")
            f(path, fullpath; io, kwargs...)
        elseif isdir(fullpath)
            if !startswith(fullpath, ".") && all(!endswith(fullpath, e) for e in exclude)
                recurse_projects(f, fullpath; io, top=false, top_proj, kwargs...)
            end
        end
    end
    top && Pkg.activate(top_proj)
end

function _update_project(path, fullpath; precomp, inst, doupdate, io=stdout)
    projpath = dirname(joinpath(path, fullpath))
    Pkg.activate(projpath; io)
    if doupdate
        prev_offline_status = Pkg.OFFLINE_MODE[]
        Pkg.offline(false)
        Pkg.update()
        Pkg.offline(prev_offline_status)
    else
        Pkg.resolve(; io)
    end
    if precomp
        Pkg.precompile(; io)
    end
    if inst
        Pkg.instantiate(; io)
    end
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
        homedir(), ".julia", "compiled", "v$(Int(VERSION.major)).$(Int(VERSION.minor))"
    )
    @info "Purging compiled cache" dir = compiled n = length(names)
    sleep(0)
    for name in names
        pkg_path = joinpath(compiled, name)
        if isdir(pkg_path)
            rm(pkg_path; recursive=true)
        end
    end
end

@doc "List of directories to put into tests.yml julia process coverage action"
function coverage_directories(sep=",")
    names = projects_name(; io=devnull)
    buf = IOBuffer()
    try
        for name in sort!([n for n in names])
            if name ∈ ("Zarr", "PingPongDev", "Cli", "PingPongInteractive", "Temporal")
                continue
            else
                write(buf, joinpath(name, "src"), sep)
            end
        end
        String(take!(buf))
    finally
        close(buf)
    end
end
