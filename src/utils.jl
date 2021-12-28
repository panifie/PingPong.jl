const pynone = PyObject(nothing)

@doc "Print a number."
function printn(n, cur="USDT"; precision=2, commas=true, kwargs...)
    println(format(n; precision, commas, kwargs...), " ", cur)
end

function in_repl()
    exc[] = get_exchange(:kucoin)
    exckeys!(exc[], values(Backtest.kucoin_keys())...)
    zi = ZarrInstance()
    exc[], zi
end

insert_and_dedup!(v::Vector, x) = (splice!(v, searchsorted(v,x), [x]); v)

export printn
