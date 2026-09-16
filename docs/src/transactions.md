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
