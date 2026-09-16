# Known limitations

These hold for engine 0.1.0, the current release. Engine 0.0.7 adds the differences listed at the
end.

- **Sessions are not released on close.** The driver never ends its server session, so a closed
  connection's session remains until the engine's 30-minute idle expiry removes it. Opening many
  short-lived connections accumulates server-side sessions.
- **An expired session silently resumes at the server's default scope.** The engine starts a fresh
  session under the expired one's id; it flags this with `newSession`, which the driver does not
  read yet. The driver re-applies the DSN's scope to a connection idle longer than `idleLimit`, but
  other session state (variables, `ALTER SESSION` settings) is lost. It stops re-applying once the
  caller issues their own `USE`, because the DSN no longer describes the session.
- **A `DateTime` holds milliseconds.** The engine sends timestamps with nanoseconds, but a
  `TIMESTAMP_NTZ` and the wall clock of a [`ZonedTimestamp`](@ref) are Julia `DateTime`s, so digits
  beyond the millisecond do not survive. `TO_VARCHAR(ts, 'YYYY-MM-DD HH24:MI:SS.FF9')` reads them.
  A `TIME` keeps its nanoseconds.
- **Fractional numbers arrive as `Float64`.** A `NUMBER(38,10)` value beyond `Float64` precision is
  rounded; only integral values are read exactly. Read such a column through `TO_VARCHAR` when the
  last digits matter.
- **Failures carry no error code.** The protocol reports only a message, with no error code or
  SQLSTATE, so [`QueryError`](@ref) has none.
- **No Tables.jl interface**, since that would add a dependency. `result.values` is the data and
  `columnnames(result)` the header, which is what most table constructors take.

## Engine 0.0.7

- A request may carry any number of statements.
- Timestamps arrive with millisecond precision and a `TIME` in whole seconds: a bound
  `Time(1, 2, 3, 456)` reads back as `01:02:03`. `TO_VARCHAR` still reads the stored fraction.
- A `TIMESTAMP_TZ` arrives at offset `+00:00` with the wall clock it was written with, so `utc(z)`
  is off by the original offset.
- An empty statement is refused by the HTTP endpoint with `SQL is required`.
- Columns carry no `length`.
