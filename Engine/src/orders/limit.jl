
function limitorder(
    ai::AssetInstance, price, amount, ::SanitizeOff; date, take=nothing, stop=nothing
)
    check_monotonic(stop, price, take)
    checkcost(ai, amount, stop, price, take)
    Orders.Order(ai; type=LimitOrder(), date, price, amount, attrs=(; take, stop))
end

function limitorder(ai::AssetInstance, price, amount; date, take=nothing, stop=nothing)
    @price! ai price take stop
    @amount! ai amount
    limitorder(ai, price, amount, SanitizeOff(); date, take, stop)
end
function limitorder(s::Strategy, ai::AssetInstance, amount; date, kwargs...)
    price = ai.data[s.timeframe][date, :open]
    limitorder(ai, price, amount; date, kwargs...)
end

function Executors.pong!(
    s::Strategy{Sim,S,E}, o::Order{LimitOrder}, ai::AssetInstance
) where {S,E<:ExchangeID}
    close, volume = ai.data[s.timeframe][o.date, [:close, :volume]]
    if volume > o.amount

    elseif volume > 0
    end
    # orders = @lget! s.orders o.asset ExchangeOrder{E}[]
    # push!(orders, o)
end
