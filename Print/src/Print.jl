module Print
using Formatting: format

@doc "Print a (currency) number."
function printn(n, cur = "USDT"; precision = 2, commas = true, kwargs...)
    println(format(n; precision, commas, kwargs...), " ", cur)
end

end # module Print
