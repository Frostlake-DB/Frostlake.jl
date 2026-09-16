# Errors

Every failure is a [`FrostlakeError`](@ref), so `e isa FrostlakeError` catches all of them. The
subtype tells what happened:

- [`QueryError`](@ref): the engine refused the statement. `message` is the engine's text,
  unmodified.
- [`ConnectionError`](@ref): no answer arrived. The host refused the connection, the socket
  failed, the deadline passed, or a proxy answered with something that is not a Frostlake
  response. The statement's outcome is unknown, so do not retry it blindly: re-running an
  `INSERT` could duplicate it.
- [`UsageError`](@ref): the driver did not send anything. Causes include a malformed DSN, a closed
  connection, a value with no SQL equivalent, or an argument count that does not match the
  placeholders.

`QueryError.statement` holds the rendered SQL with every parameter inlined, so a bound password
appears in it verbatim. The error's printed form and `message` do not include it: log those, and
treat `statement` as sensitive.
