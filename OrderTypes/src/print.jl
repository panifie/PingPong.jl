using Instruments: compactnum as cnum

@doc "Prints the number of trades in the order."
function _printtrades(io, o)
    hasproperty(o.attrs, :trades) && begin
        write(io, "Trades: ")
        write(io, string(length(o.attrs.trades)))
    end
end

# vector or value
_vv(v) = v isa Vector ? v[] : v
@doc "Prints the number of committed order amount."
function _printcommitted(io, o)
    hasproperty(o.attrs, :committed) && begin
        write(io, "\nCommitted: ")
        write(io, string(cnum(_vv(o.attrs.committed[]))))
    end
end
@doc "Prints the number of unfilled order amount."
function _printunfilled(io, o)
    hasproperty(o.attrs, :unfilled) && begin
        write(io, "\nUnfilled: ")
        write(io, cnum(_vv(o.attrs.unfilled[])))
    end
end

function Base.display(io::IO, o::Order)
    write(io, replace(string(ordertype(o)), "$(@__MODULE__)." => ""))
    write(io, "($(positionside(o)))")
    write(io, "\n")
    write(io, string(o.asset))
    write(io, "(")
    write(io, string(o.exc))
    write(io, "): amount~ ")
    write(io, string(cnum(o.amount)))
    write(io, " @ ")
    write(io, string(cnum(o.price)))
    write(io, " ~price\n")
    _printtrades(io, o)
    _printcommitted(io, o)
    _printunfilled(io, o)
    write(io, "\nDate: ")
    write(io, string(o.date))
end

function Base.display(io::IO, t::Trade)
    write(io, "Trade($(positionside(t))): ")
    write(io, cnum(t.amount))
    write(io, " at ")
    write(io, cnum(abs(t.size / t.amount)))
    write(io, " (size $(cnum(t.size)))")
    write(io, " (lev $(cnum(t.leverage))) ")
    write(io, string(t.date))
    write(io, "\n")
    display(io, t.order)
end
Base.display(t::Trade) = display(stdout, t)

_verb(o::AnyBuyOrder) = "Buy"
_verb(o::AnySellOrder) = "Sell"
_pside(o::LongOrder) = "(Long)"
_pside(o::ShortOrder) = "(Short)"

function Base.show(io::IO, o::Order)
    write(io, replace(string(nameof(ordertype(o))), "OrderType" => ""))
    write(io, " ")
    write(io, _verb(o))
    write(io, _pside(o))
    write(io, " ")
    write(io, cnum(o.amount))
    write(io, " ")
    write(io, o.asset.bc)
    write(io, " on ")
    write(io, string(o.exc))
    write(io, " at ")
    write(io, cnum(o.price))
    write(io, " ")
    write(io, o.asset.qc)
end
Base.display(o::Order) = Base.display(stdout, o)
