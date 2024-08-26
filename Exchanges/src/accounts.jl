@doc "The accounts available for the exchange."
accounts(::Exchange) = [""]
@doc "The account currently being used by the exchange."
current_account(exc::Exchange) = account(exc)
