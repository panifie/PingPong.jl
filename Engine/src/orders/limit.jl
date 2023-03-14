
function LimitOrder(
    ai::AssetInstance, price, amount, ::SanitizeOff; date, take=nothing, stop=nothing
)
    check_monotonic(stop, price, take)
    checkcost(ai, amount, stop, price, take)
    Orders.Order(ai; type=typeof(Limit), date, price, amount, attrs=(; take, stop))
end

function LimitOrder(ai::AssetInstance, price, amount; date, take=nothing, stop=nothing)
    @price! ai price take stop
    @amount! ai amount
    LimitOrder(ai, price, amount, SanitizeOff(); date, take, stop)
end

function LimitOrder(s::Strategy, ai::AssetInstance, amount; date, kwargs...)
    price = ai.data[s.timeframe][date, :open]
    LimitOrder(ai, price, amount; date, kwargs...)
end

function Executors.pong!(s::Strategy{M,E} where {M}, o::Order{Limit}) where {E}
    orders = @lget! s.orders o.asset ExchangeOrder{E}[]
    push!(orders, o)
end
