# Why PingPong?

```@eval
using Markdown
let lines = readlines("../../README.md", keep=true)
start_idx = 1
line = ""
while !occursin("PRESENTATION BEGIN", lines[start_idx])
    start_idx+=1
end
stop_idx = start_idx + 1
while !occursin("PRESENTATION END", lines[stop_idx])
    stop_idx+=1
end
join(lines[start_idx+1:stop_idx-1]) |> Markdown.parse
end

```
