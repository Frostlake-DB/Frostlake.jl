# Connecting

```julia
conn = Connection("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
# ...
close(conn)
```

[`Connection`](@ref) contacts the server before it returns: it calls the health endpoint and
applies the scope the DSN names, so a database that does not exist is reported at connect time
rather than on the first query.

The do-block form closes the connection however the block exits:

```julia
Connection("frostlake://localhost:18082") do conn
    scalar(execute(conn, "SELECT CURRENT_VERSION()"))
end
```

`Frostlake.connect` is the same function under the familiar name. It is not exported because
`Sockets` exports `connect`.

## DSN

```
frostlake://host[:port][/DATABASE][?param=value&…]
```

`http://` and `https://` are accepted too and mean the same thing. Without a port, `frostlake://`
uses the engine's default, 18082, and `http`/`https` use their standard ports. Write an IPv6
address in brackets: `frostlake://[::1]:18082`.

| Parameter | Meaning | Default |
| --- | --- | --- |
| `schema` | schema to `USE` on the session | — |
| `role` | role to `USE` on the session | — |
| `warehouse` | warehouse to `USE` on the session | — |
| `timeout` | how long one statement may take; `0` removes the limit | `5m` |
| `connectTimeout` | how long to wait for the socket | `10s` |
| `idleLimit` | idle time after which the DSN's scope is re-applied; `0` disables the check | `30m` |
| `tls` | `true` to use HTTPS, like an `https://` DSN | `false` |

Durations are a number of seconds or carry an `ms`, `s`, `m` or `h` suffix. An unknown parameter
is an error, and so is a username or password: the HTTP API has no authentication, and silently
dropping a password would hide that. The parameter names match the other Frostlake drivers, so one
DSN works with all of them.

## Keyword arguments

`timeout`, `connect_timeout` and `idle_limit` can also be passed to `Connection`, as seconds or as
a fixed-length `Dates.Period` such as `Minute(10)`; an explicit argument overrides the DSN.
`cacert` and `verify_certificate` configure HTTPS.

```julia
Connection("https://warehouse.internal/MY_DB"; timeout=Minute(10), cacert="/etc/ca.pem")
```
