let tries = 0
    while tries < 2
        try
            include("noprecomp.jl")
            using Pkg
            Pkg.add(["Documenter", "DocStringExtensions", "Suppressor"])
            Pkg.instantiate()
            Pkg.precompile()
            Pkg.precompile()
            break
        catch e
            tries += 1
            Base.showerror(stderr, e)
        end
    end
end
