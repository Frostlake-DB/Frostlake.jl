# frostlake-julia

A dependency-free Julia driver for [Frostlake](https://frostlake.dev), speaking the engine's
HTTP protocol against a running `DatabaseHttpServer`. Standard library only — `Downloads` for
the transport and `Dates` for the temporal types — so `Project.toml` names no packages at all.
No JVM, no native library, nothing to build.

## Engine version

Requires a Frostlake engine **0.0.7 or newer**. Ask a running server which one it is with
`SELECT CURRENT_VERSION()` — every release answers it, so the check works against any engine.

The driver versions independently of the engine: it speaks the HTTP protocol, not the jar, so
this is a floor rather than a lockstep pin.

## Install

Not registered yet, so add it by path or URL:

```julia
using Pkg
Pkg.add(url="https://github.com/Frostlake-DB/Frostlake.jl")
```

Julia 1.10 or newer.

## Usage

```julia
using Frostlake

conn = Connection("frostlake://localhost:18082/MY_DB?schema=PUBLIC")

execute(conn, "CREATE TABLE people (id INTEGER, name VARCHAR)")

inserted = execute(conn, "INSERT INTO people VALUES (?, ?), (?, ?)",
                   [1, "Ada", 2, "Grace"])
inserted.updatecount            # 2

result = execute(conn, "SELECT id, name FROM people WHERE id = ?", [1])
rows(result)[1]["NAME"]         # "Ada"

close(conn)
```

`Connection` contacts the server before it returns: it calls the health endpoint and applies
the scope the DSN names, so a database that does not exist is reported there rather than
surfacing later on whichever query happened to run first.

The do-block form closes on the way out, however the body leaves:

```julia
Connection("frostlake://localhost:18082") do conn
    scalar(execute(conn, "SELECT CURRENT_VERSION()"))
end
```

Two names are deliberately not exported. `connect` is `Sockets`' name — `Frostlake.connect` is
the same function for anyone who wants the familiar spelling — and `value` is `Dates`', which
is why the single-cell accessor is `scalar`. Everything else in the table below is exported.

### DSN

```
frostlake://host[:port][/DATABASE][?param=value&…]
```

`http://` and `https://` are accepted too and mean the same thing. Omitting the port means the
engine's own default, `18082`; for `http`/`https` it means their standard ports. An IPv6
address goes in brackets: `frostlake://[::1]:18082`.

| Parameter | Meaning | Default |
| --- | --- | --- |
| `schema` | schema to `USE` on the session | — |
| `role` | role to `USE` on the session | — |
| `warehouse` | warehouse to `USE` on the session | — |
| `timeout` | how long one statement may take; `0` removes the bound | `5m` |
| `connectTimeout` | how long to wait for the socket | `10s` |
| `idleLimit` | how long a connection may idle before its scope is re-applied; `0` switches the check off | `30m` |
| `tls` | `true` to speak HTTPS — an `https://` DSN does the same | `false` |

Durations are written as a bare number of seconds or with a `ms`/`s`/`m`/`h` suffix. An unknown
parameter is an error rather than a silent no-op, and so is a username or password — the
engine's HTTP API has no authentication to hand them to, and quietly dropping a password is
worse than saying so. The spellings match the other Frostlake drivers, so one DSN string works
across all of them.

`timeout`, `connect_timeout` and `idle_limit` can also be passed to `Connection` directly —
as seconds or as any `Dates.Period` — where an explicit argument outranks the DSN.
`cacert` and `verify_certificate` are there for HTTPS.

```julia
Connection("https://warehouse.internal/MY_DB"; timeout=Minute(10), cacert="/etc/ca.pem")
```

### Results

`execute` returns a `Result`:

| Member | What it holds |
| --- | --- |
| `result.columns` | a `ColumnInfo` per column: name, declared type, nullability, precision, scale |
| `result.values` | every cell, positionally aligned with `columns` — the lossless view |
| `result.updatecount` | rows affected by DML, or `-1` when the statement returned data |
| `result.counters` | the raw `number of rows …` counters behind `updatecount` |
| `rows(result)` | each row keyed by column name, built on first use |
| `scalar(result)` | the first cell of the first row, for a single-value query |
| `rowcount(result)` | rows returned, or rows affected for DML |
| `isupdate(result)` | whether this came from DML rather than a query |
| `columnnames(result)` | the column names, in order |

A `Result` iterates and indexes over its rows, so it drops into ordinary Julia code:

```julia
for row in result
    println(row[1], " ", row[2])
end

result[1]           # the first row, positionally
result[1, 2]        # ... one cell of it
result[1, "NAME"]   # ... by column name, case-insensitively
map(row -> row[1], result)
```

`rows` cannot represent two columns called the same thing — a self-join reports `ID` twice and
the later one wins — which is why `values` is there.

A statement string holding several `;`-separated statements answers with one result each:
`execute_all` returns them all, and `execute` hands back the first.

### Bind values

Parameters are inlined client-side — the protocol has no server-side binding — with the same
rules as Frostlake's JDBC driver. A `?` inside a string literal, quoted identifier, `$$…$$`
body or comment is never a placeholder, and the argument count has to match exactly whenever
arguments are supplied. With no arguments at all the markers pass through to the server: a `?`
is then a Snowflake Scripting cursor placeholder bound by `OPEN c USING (...)`, and `:name` a
Scripting variable.

| Julia value | SQL literal |
| --- | --- |
| `nothing`, `missing` | `NULL` |
| `Bool` | `TRUE` / `FALSE` |
| `Integer` (`Int`, `BigInt`, …) | the digits, exactly |
| `AbstractFloat` | the shortest round-tripping form; NaN and the infinities cast from text |
| `AbstractString` | `'…'`, backslashes and quotes escaped |
| `Vector{UInt8}` | `X'hex'` |
| `Date` | `'…'::DATE` |
| `Time` | `'…'::TIME` |
| `DateTime` | `'…'::TIMESTAMP_NTZ` |
| `ZonedTimestamp` | `'…'::TIMESTAMP_TZ`, carrying its offset |
| `AbstractVector` | `[…]`, elements formatted recursively |
| `AbstractDict` | `{'key': …}`, values formatted recursively |

`Vector{UInt8}` is Julia's bytes type and the deliberate marker for binary; a `Vector{Int}` is
an array of numbers. Snowflake has both, and guessing between them from the element type would
make `[1, 2, 3]` mean two different things.

A Julia `DateTime` is a wall clock with no zone of its own, which is exactly what
`TIMESTAMP_NTZ` is — casting it to `TIMESTAMP_TZ` would invent an offset the value never had.
Bind a `ZonedTimestamp` when the offset is real.

Statements may use positional `?` or named `:name` placeholders, one style per statement.
Named arguments come as a dictionary or a named tuple, whichever reads better:

```julia
execute(conn, "SELECT :a + :b AS total", (a=2, b=40))
execute(conn, "SELECT :a + :b AS total", Dict("a" => 2, "b" => 40))
```

Names match case-insensitively and their order does not matter. A `::` cast, a `:=` assignment
and a `:1` positional reference are never parameters — and neither is Snowflake's VARIANT path
access: a colon glued to the end of an expression (`v:field`, `PARSE_JSON('…'):k`, `"V":k`)
reads a field, so a bind marker has to follow an operator, comma or keyword boundary. With **no
arguments at all**, colon references pass through to the server untouched, because that is what
Snowflake Scripting variables look like (`EXECUTE IMMEDIATE :v`, `IFF(:flag, …)`).

### Types coming back

| SQL type | Julia type |
| --- | --- |
| integral `NUMBER`, `INTEGER` and friends | `Int64`, or `BigInt` past 64 bits |
| fractional `NUMBER`, `FLOAT`, `DOUBLE`, `REAL` | `Float64` |
| `VARCHAR` and the text types | `String` |
| `BOOLEAN` | `Bool` |
| `BINARY` | `Vector{UInt8}` |
| `DATE` | `Date` |
| `TIME` | `Time` |
| `TIMESTAMP`, `TIMESTAMP_NTZ`, `DATETIME` | `DateTime` |
| `TIMESTAMP_LTZ`, `TIMESTAMP_TZ` | `ZonedTimestamp` |
| `VARIANT`, `OBJECT`, `ARRAY` | `String`, the engine's own rendering |
| SQL `NULL` | `nothing` |

A `NUMBER(38,0)` holds integers no `Int64` can name. The driver's JSON layer keeps every
number's literal text rather than resolving it while parsing, so those arrive as an exact
`BigInt` instead of the rounded `Float64` a conventional parser would produce — which is the
whole reason the package carries its own JSON reader.

Julia's standard library has no zoned type, so `TIMESTAMP_TZ` and `TIMESTAMP_LTZ` become a
`ZonedTimestamp`: the wall clock (`z.datetime`) and the offset it was written at (`z.offset`),
side by side. `utc(z)` gives the instant, which is what to compare two of them by. Folding the
offset in and handing back a bare `DateTime` would lose it.

A `Date` and a `DateTime` are wall clocks with no zone of their own, so their fields read back
exactly as stored rather than being shifted by whatever zone the host is in.

### Transactions

```julia
transaction(conn) do c
    execute(c, "INSERT INTO acc VALUES (1)")
end
```

The helper commits when the body returns and rolls back when it throws, re-raising the original
error either way, and hands back whatever the body returned. `begin_transaction`, `commit` and
`rollback` are there for hand-rolled control. The engine offers read committed.

A transaction lives on the session, not on the closure, so anything else run on the same
connection meanwhile joins it. Give a transaction its own connection if that is not what you
want.

### Errors

Every failure is a `FrostlakeError`, so one `e isa FrostlakeError` catches the lot. The
subtypes say which kind it was, which is the distinction a caller actually branches on:

- **`QueryError`** — the engine refused the statement. `message` is the engine's own wording,
  unmodified.
- **`ConnectionError`** — the request never became an answer: the host refused, the socket
  died, the deadline passed, or a proxy replied with something that is not a Frostlake
  response. A statement that failed this way has an *unknown* fate, so it must not be blindly
  retried — re-running an `INSERT` would duplicate it.
- **`UsageError`** — the driver never sent it: a malformed DSN, a closed connection, a bind
  value with no SQL equivalent, an argument count that does not match the placeholders.

**`QueryError.statement` holds the rendered SQL.** Because binding is client-side, that means
every parameter inlined — a bound password or card number appears in it verbatim. The printed
error and `message` carry none of it, so log those freely and treat `statement` as sensitive.

### Sessions and concurrency

One HTTP session per `Connection`. Statements on a connection are serialized, so several tasks
may share one and stay on one session — which is what keeps `USE`, session variables and an
open transaction carrying from one statement to the next.

```julia
tasks = [@async execute(conn, "INSERT INTO t VALUES (?)", [i]) for i in 1:8]
foreach(wait, tasks)   # serialized, one session
```

For genuine parallelism, give each task its own connection. Sockets are reused, which is
libcurl's default; `close` releases them.

## Known limitations

Measured against engine 0.0.7, the current release.

- **Server sessions are not released on close.** The HTTP API has no endpoint for ending a
  session, so a closed connection's session lingers until the engine's own 30-minute idle sweep
  reclaims it. Connection churn therefore accrues server-side sessions.
- **A session idle past that sweep silently resumes at the server's default scope**, because
  the engine re-creates an expired session under the very same id — nothing in the answer tells
  a client its session was reclaimed. The driver covers this by re-applying the DSN's scope to
  a connection that has been idle longer than `idleLimit`, but anything else the session held
  (a session variable, an `ALTER SESSION` setting) is gone. It stops doing so once the caller
  has issued their own `USE`, since the DSN no longer describes where they are.
- **Timestamps carry milliseconds in transit.** The engine holds full nanoseconds, but the HTTP
  layer serialises milliseconds, so a temporal cell arrives millisecond-precise however fine
  the stored value — which is also all a Julia `DateTime` can hold.
  `TO_VARCHAR(ts, 'YYYY-MM-DD HH24:MI:SS.FF9')` is the way to read the rest. A `TIME` arrives
  in whole seconds: the engine keeps its fraction, but the HTTP layer drops it, so a bound
  `Time(1, 2, 3, 456)` reads back as `01:02:03`, while `TO_VARCHAR(t, 'HH24:MI:SS.FF9')`
  returns `01:02:03.456000000`.
- **Fractional numerics arrive as `Float64`.** A `NUMBER(38,10)` wider than a `Float64` can
  represent is rounded; only the integral ones get the exact `BigInt` treatment. Read such a
  column through `TO_VARCHAR` when the last digits matter.
- **Failures carry no error code.** The protocol reports a message only — no code, no SQLSTATE
  — so `QueryError` has none to offer.
- **A blank statement is refused by the endpoint**, with HTTP 400 and `SQL is required`, before
  the engine sees it; the engine's own `Empty SQL statement.` wording never reaches a client
  over this transport.
- **No `Tables.jl` interface**, which would mean a dependency — so a `Result` does not drop
  straight into `DataFrame` and friends. `result.values` is the grid and `columnnames(result)`
  its header, which is what a table constructor wants.

## Tests

The unit tests need nothing installed — no engine, no JVM:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

The integration tests additionally boot a real server from an engine classpath, and skip
themselves when `FROSTLAKE_CLASSPATH` is unset, so an unconfigured run is never falsely green:

```bash
JAVA_HOME=/path/to/jdk17 FROSTLAKE_CLASSPATH="<engine classes>:<dependency classpath>" julia --project -e 'using Pkg; Pkg.test()'
```

The classpath is handed to `java -cp` as written, so its separator is the platform's: `:` on
Linux and macOS, `;` on Windows.

Those drive a real engine over the driver's own HTTP path — DDL and DML, every type that can be
bound and read back, transactions, session scope, concurrency, and the transport failures — so
nothing in them is mocked.

## License

Apache-2.0 — see [LICENSE](LICENSE).
