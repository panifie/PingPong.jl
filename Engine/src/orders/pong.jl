@doc "Iterates over all pending orders checking for new fills. Should be called only once, precisely at the beginning of a `ping!` function."
function Executors.pong!(s::Strategy{Sim}, date, ::UpdateOrders)
    for (ai, ords) in s.sellorders
        for o in ords
            Orders.pong!(s, o, date, ai)
        end
    end
    for (ai, ords) in s.buyorders
        for o in ords
            Orders.pong!(s, o, date, ai)
        end
    end
end
