# Transactions and sessions

## Transactions

```julia
transaction(conn) do c
    execute(c, "INSERT INTO acc VALUES (1)")
end
```

[`transaction`](@ref) commits when the block returns and rolls back when it throws, rethrowing the
original error; it returns the block's value. [`begin_transaction`](@ref), [`commit`](@ref) and
[`rollback`](@ref) give manual control. The engine provides read-committed isolation.

A transaction belongs to the session, not to the block, so any other statement run on the same
connection meanwhile joins it. Use a separate connection when that is not wanted.

## Sessions and concurrency

Each `Connection` holds one HTTP session. Statements on a connection are serialized, so several
tasks can share it and stay on the same session; that is what carries `USE`, session variables and
an open transaction from one statement to the next.

```julia
tasks = [@async execute(conn, "INSERT INTO t VALUES (?)", [i]) for i in 1:8]
foreach(wait, tasks)   # serialized, one session
```

For real parallelism, give each task its own connection.

## Session lifetime

The engine can lose a session: it expires one after 30 idle minutes, a `DELETE
/api/sessions/{id}` releases one, and a restart ends them all. Against an engine from 0.1.0 on —
one whose answers carry `newSession` — the connection keeps its session in step:

- **What is sent.** Every request that names the session also sends `requireSession: true`, so an
  engine that no longer holds the session refuses the request with HTTP 404 and runs nothing,
  rather than quietly starting a fresh session at its default scope. The first answer that names
  a session says whether the engine understands the flag: `newSession` present means it does. An
  engine before 0.1.0 is never sent the flag.
- **After a lost session.** The connection drops the session and decides from what the lost one
  held.
  - Nothing of the caller's own: the DSN's scope (`USE ROLE`, `WAREHOUSE`, `DATABASE`, `SCHEMA`)
    goes onto a fresh session and the statement is sent **once** more. A second refusal throws
    [`SessionLostError`](@ref).
  - An open transaction — from [`begin_transaction`](@ref) or a `BEGIN` / `START TRANSACTION`
    statement, until `COMMIT` or `ROLLBACK`: `SessionLostError`, saying the transaction is gone
    and the statement did not run.
  - Context the caller set up — a `USE`, `SET` / `UNSET`, `ALTER SESSION`, a temporary object, or
    a `CREATE` / `DROP` of a database or schema: `SessionLostError`, saying the context went with
    the session and the statement was not re-run. [`apply_dsn_scope`](@ref) puts the connection
    back on the DSN's scope, and after it a lost session is replaced again.

  Either way the connection stays usable: the next statement starts a fresh session on the DSN's
  scope, in autocommit.
- **What `close` does.** It sends `DELETE /api/sessions/{id}`, which releases the session and
  rolls back a transaction left open on it. The release is best effort: it waits five seconds at
  most (less when `timeout` is shorter), and a release the engine refuses or never answers is not
  an error. Closing again sends nothing.

Against an engine before 0.1.0 none of this applies: it cannot say that a session was lost, so the
connection re-applies the DSN's scope after `idleLimit` of idleness instead, and `close` sends
nothing, leaving the session to the engine's own idle expiry.
