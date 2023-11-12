module PingPongInteractive

using Pkg: Pkg

if isdefined(Main, :PingPong) && Main.PingPong isa Module
    error(
        """Can't load PingPongInteractive because PingPong has already been loaded.
  Restart the repl and run `Pkg.activate("PingPongInteractive"); using PingPongInteractive;`
  """
    )
end

let this_proj = Symbol(Pkg.project().name), ppi_proj = nameof(@__MODULE__)
    if this_proj != ppi_proj
        error(
            "PingPongInteractive should only be loaded after activating it's project dir. ",
            this_proj,
            " ",
            ppi_proj,
        )
    end
end

using PingPong
using WGLMakie
using Plotting
using Optimization
using Watchers
using Scrapers

export Plotting, Optimization, Watchers, Scrapers

end # module IPingPong
