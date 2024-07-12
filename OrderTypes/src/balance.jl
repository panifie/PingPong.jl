struct BalanceUpdated{E} <: ExchangeEvent{E}
    tag::Symbol
    group::Symbol
    data::NamedTuple
    function BalanceUpdated(obj, tag, group, balance)
        new{exchangeid(obj)}(Symbol(tag), Symbol(group), (; balance))
    end
end
