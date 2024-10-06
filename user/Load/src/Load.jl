module Load
using PrecompileTools

@compile_workload begin
    using PingPong
    using Stubs
    using Scrapers
    using Metrics
end

end # module Load
