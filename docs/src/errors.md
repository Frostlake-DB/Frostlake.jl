# Errors

Every failure is a [`FrostlakeError`](@ref), so `e isa FrostlakeError` catches all of them. The
subtype tells what happened:

- [`QueryError`](@ref): the engine refused the statement. `message` is the engine's text,
  unmodified.
- [`ConnectionError`](@ref): no answer arrived. The host refused the connection, the socket
  failed, the deadline passed, or a proxy answered with something that is not a Frostlake
  response. The statement's outcome is unknown, so do not retry it blindly: re-running an
  `INSERT` could duplicate it.
- [`SessionLostError`](@ref): the engine no longer held the connection's session, and the
  statement did not run, nor was it re-run: the lost session held an open transaction or context
  of the caller's own. The connection stays usable; see [Session lifetime](@ref).
- [`UsageError`](@ref): the driver did not send anything. Causes include a malformed DSN, a closed
  connection, a value with no SQL equivalent, or an argument count that does not match the
  placeholders.

`QueryError.statement` and `SessionLostError.statement` hold the rendered SQL with every
parameter inlined, so a bound password appears in them verbatim. The error's printed form and `message` do not include it: log those, and
treat `statement` as sensitive.
