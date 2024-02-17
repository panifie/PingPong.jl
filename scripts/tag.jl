using Base.TOML

function tag_repo(; major=nothing, minor=nothing, patch=nothing)
    Pkg.activate("PingPong")
    p = Pkg.project()
    v = p.version
    if isnothing(major)
        major = v.major
        patch = if isnothing(minor)
            minor = v.minor
            @something patch v.patch + 1
        else
            0
        end
    elseif isnothing(minor)
        minor = 0
        patch = 0
    else
    end
    toml = TOML.parsefile(p.path)
    toml["version"] = string(VersionNumber(major, minor, patch))
    open(p.path, "w") do f
        TOML.print(f, toml)
    end
    Pkg.activate("PingPongInteractive")
    Pkg.resolve()
    Pkg.activate("PingPongDev")
    Pkg.resolve()
    Pkg.activate("PingPong")
    run(`git add PingPong/Project.toml PingPongDev/Manifest.toml PingPongInteractive/Manifest.toml`)
end
