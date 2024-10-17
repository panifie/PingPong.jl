@doc "Buy or Sell"
@enum TradeSide buy sell
@doc "Taker Or Maker"
@enum TradeRole taker maker

const FeesType = Union{Nothing,DFT,<:NamedTuple{(:cost, :currency), <:Tuple{<:Option{DFT},<:Option{DFT}}}}
@doc """A named tuple representing a trade in the CCXT (CryptoCurrency eXchange Trading) library.

$(FIELDS)

"""
const CcxtTrade = @NamedTuple begin
    timestamp::DateTime
    symbol::String
    order::Option{String}
    type::Option{String}
    side::TradeSide
    takerOrMaker::Option{TradeRole}
    price::DFT
    amount::DFT
    cost::DFT
    fee::FeesType
    fees::Vector{FeesType}
end

TradeSide(v) = getproperty(@__MODULE__, Symbol(v))
TradeRole(v) = getproperty(@__MODULE__, Symbol(v))
Base.convert(::Type{TradeSide}, v) = TradeSide(v)
Base.convert(::Type{TradeRole}, v) = TradeRole(v)

export CcxtTrade, TradeSide, TradeRole, FeesType
