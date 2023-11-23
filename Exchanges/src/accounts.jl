@doc "The accounts available for the exchange."
accounts(::Exchange) = ["main"]
@doc "The account currently being used by the exchange."
current_account(exc::Exchange) = "main"
