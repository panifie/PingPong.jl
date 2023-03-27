using Pkg
ENV["JULIA_NOPRECOMP"] = (:PingPong, :Scrapers, :Engine, :Watchers, :Plotting, :Stats)
Pkg.add(["Documenter", "DocStringExtensions"]);
include("../resolve.jl")
update_projects(inst=true)
