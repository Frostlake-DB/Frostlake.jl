"""
    Frostlake

A driver for [Frostlake](https://frostlake.dev), speaking the engine's HTTP
protocol against a running `DatabaseHttpServer`.

```julia
using Frostlake

conn = Connection("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
execute(conn, "CREATE TABLE people (id INTEGER, name VARCHAR)")
execute(conn, "INSERT INTO people VALUES (?, ?)", [1, "Ada"])
result = execute(conn, "SELECT name FROM people WHERE id = ?", [1])
scalar(result)  # "Ada"
close(conn)
```

Nothing outside the standard library is needed: the JSON reader, the DSN parser
and the SQL scanner are all in the package, and the transport is `Downloads`.
"""
module Frostlake

using Dates
using Downloads

export
    # connecting
    Connection, ping, apply_dsn_scope, session_id, in_transaction, base_url,
    # statements
    execute, execute_all,
    # transactions
    transaction, begin_transaction, commit, rollback,
    # results
    Result, ColumnInfo, rows, scalar, rowcount, isupdate, columnnames, columnindex,
    # values
    ZonedTimestamp, utc,
    # failures
    FrostlakeError, ConnectionError, QueryError, UsageError

# Two names are deliberately avoided, because a caller who also loads the
# standard library module that owns them would find them ambiguous rather than
# convenient: `connect`, which `Sockets` exports — hence `Connection(dsn)`, with
# `Frostlake.connect` there unexported for anyone who wants the familiar
# spelling — and `value`, which `Dates` exports, hence `scalar`.

include("errors.jl")
include("json.jl")
include("sql.jl")
include("result.jl")
include("values.jl")
include("binding.jl")
include("dsn.jl")
include("connection.jl")

end # module Frostlake
