# Control the bot remotely

A pingpong strategy can be controlled with telegram. 

## Requirements
Create a new telegram bot:
- Initiate a chat with `BotFather`
- send the `/start` command
- follow the prompts
Get a `chat_id`:
- Initiate a chat with `userinfobot`
- send the name of the bot you created, e.g. `@mynewbot`
- use the `Id` in the response as your `chat_id`

Once you have the token and the id, save them either:
- in the strategy config file as keys `tgtoken` and `tgchat_id`
- after loading the strategy object in the strategy attributes (same keys (`Symbol`) as config)
- as env vars `TELEGRAM_BOT_TOKEN` and `TELEGRAM_BOT_CHAT_ID`.

## The telegram client
Start listening for commands:

``` julia
using PingPong
PingPoing.Remote.tgstart!(s) # where s is your strategy object
```

Now you can start a chat with your telegram bot.
The supported commands are:

- `start`: start the strategy
- `stop`: stop the strategy
- `status`: show summary
- `daily`: rolling 1d history
- `weekly`: rolling 7d history
- `monthly`: rolling 30d history
- `balance`: show current balance
- `assets`: trades history by asset
- `config`: show toml config
- `logs`: upload most recent logs
- `set`: set a strategy attribute
- `get`: get a strategy attribute

To manually stop the telegram bot:

``` julia
PingPoing.Remote.tgstop!(s) # where s is your strategy object
```

To prevent the bot from talking with strangers you can set a specific username that the bot is allowed to talk to by setting the `tgusername`(`Symbol`) key to your desired telegram username.
