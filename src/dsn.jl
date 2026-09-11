# Parsing a DSN into everything a connection needs.
#
# Julia's standard library has no URI parser, so the grammar is spelled out
# here. It is a small one, and owning it keeps the package dependency-free.

"The port a `DatabaseHttpServer` listens on unless told otherwise."
const DEFAULT_PORT = 18082

# Long enough for a slow query, short enough that an unreachable host fails
# while someone is still watching. Seconds; 0 means no bound.
const DEFAULT_CONNECT_TIMEOUT = 10.0
const DEFAULT_REQUEST_TIMEOUT = 300.0

# The engine reclaims a session after 30 minutes idle. Past that the driver has
# to assume its own is gone, because nothing in a response says so.
const DEFAULT_IDLE_LIMIT = 1800.0

# Everything the DSN query string may carry. Anything else is a typo, and a typo
# in `schema` or `timeout` changes behaviour without saying so. The spellings
# match the other Frostlake drivers, so one DSN string works across all of them.
const DSN_PARAMETERS = ("connectTimeout", "idleLimit", "role", "schema",
                        "timeout", "tls", "warehouse")

"""
    Config

A parsed DSN: everything a [`Connection`](@ref) needs to reach a server and put
a session on the right scope. Timeouts are seconds, where `0` means no bound.
"""
struct Config
    host::String
    port::Int
    "Whether to speak HTTPS."
    secure::Bool
    database::Union{String,Nothing}
    schema::Union{String,Nothing}
    role::Union{String,Nothing}
    warehouse::Union{String,Nothing}
    "How long to wait for the socket itself."
    connect_timeout::Float64
    "How long one statement may take; `0` removes the bound."
    timeout::Float64
    "How long a connection may idle before the driver stops trusting its engine session; `0` switches the check off."
    idle_limit::Float64
end

Config(; host, port=DEFAULT_PORT, secure=false, database=nothing, schema=nothing,
       role=nothing, warehouse=nothing, connect_timeout=DEFAULT_CONNECT_TIMEOUT,
       timeout=DEFAULT_REQUEST_TIMEOUT, idle_limit=DEFAULT_IDLE_LIMIT) =
    Config(String(host), Int(port), Bool(secure), database, schema, role, warehouse,
           Float64(connect_timeout), Float64(timeout), Float64(idle_limit))

"The base URL of the server, without a trailing slash."
base_url(config::Config) =
    string(config.secure ? "https" : "http", "://", config.host, ":", config.port)

"""
    use_statements(config) -> Vector{String}

The DSN's scope rendered as the `USE` statements a fresh session needs, in
dependency order. Rebuilt on demand, so a session that may have lapsed can be
put back on this scope.
"""
function use_statements(config::Config)
    out = String[]
    config.role === nothing || push!(out, string("USE ROLE ", use_identifier(config.role)))
    config.warehouse === nothing ||
        push!(out, string("USE WAREHOUSE ", use_identifier(config.warehouse)))
    config.database === nothing ||
        push!(out, string("USE DATABASE ", use_identifier(config.database)))
    config.schema === nothing ||
        push!(out, string("USE SCHEMA ", use_identifier(config.schema)))
    return out
end

"""
    quote_identifier(name) -> String

Quotes an identifier for use in a statement.

Always quoted. Leaving "unambiguous" names bare lets through ones that cannot
legally appear that way — `1ABC` starts with a digit, `SELECT` is reserved — and
quoting costs nothing: `"NAME"` and `NAME` name the same object, so only
genuinely lower-case names are affected, and those had to be quoted anyway.
Embedded quotes are doubled, so a name arriving from a DSN cannot break out.
"""
function quote_identifier(name::AbstractString)
    isempty(name) && throw(UsageError("an identifier cannot be empty"))
    return string('"', replace(String(name), '"' => "\"\""), '"')
end

"""
    use_identifier(name) -> String

A DSN name as a `USE` statement needs it. A plain name means what it means
unquoted in SQL — the upper-case object it folds to — so it is folded before it
is quoted; anything else is quoted exactly as given. Quoted as given, a
lower-case name would ask for a lower-case object, which `USE` refuses: it
resolves names exactly, as live does.
"""
use_identifier(name::AbstractString) =
    quote_identifier(occursin(r"^[A-Za-z_][A-Za-z0-9_$]*$", name) ? uppercase(name) : name)

const _DSN_PATTERN = r"^([A-Za-z][A-Za-z0-9+.\-]*)://([^/?#]*)([^?#]*)(?:\?([^#]*))?$"

"""
    parse_dsn(dsn) -> Config

Parses a DSN of the form `frostlake://host[:port][/DATABASE][?param=value&...]`.

`http://` and `https://` are accepted too and mean the same thing; the custom
scheme exists so a DSN reads as a database URL rather than a web one.
"""
function parse_dsn(dsn::AbstractString)
    m = match(_DSN_PATTERN, String(dsn))
    m === nothing &&
        throw(UsageError("a DSN must start with frostlake://, http:// or https://"))

    scheme = lowercase(String(m[1]))
    (scheme == "frostlake" || scheme == "http" || scheme == "https") ||
        throw(UsageError("a DSN must start with frostlake://, http:// or https://"))

    authority = String(m[2])
    # The server authenticates nobody, so credentials in a DSN would be silently
    # dropped — and silently dropping a password is worse than saying so.
    occursin('@', authority) &&
        throw(UsageError("the server takes no credentials; remove user:password from the DSN"))

    host, port = _split_authority(authority, scheme)
    isempty(host) && throw(UsageError("the DSN is missing host[:port]"))
    (1 <= port <= 65535) ||
        throw(UsageError(string("the DSN port must be between 1 and 65535, got ", port)))

    path = String(m[3])
    segments = [s for s in split(path, '/') if !isempty(s)]
    length(segments) > 1 &&
        throw(UsageError(string("the DSN path names one database, got \"", path, "\"")))
    database = isempty(segments) ? nothing : _percent_decode(String(segments[1]))

    query = _parse_query(m[4] === nothing ? "" : String(m[4]))
    unknown = sort!([k for k in keys(query) if !(k in DSN_PARAMETERS)])
    isempty(unknown) ||
        throw(UsageError(string("unknown DSN parameter: ", join(unknown, ", "),
                                " (expected ", join(DSN_PARAMETERS, ", "), ")")))

    secure = scheme == "https"
    haskey(query, "tls") && _parse_bool("tls", query["tls"]) && (secure = true)

    return Config(
        host=host,
        port=port,
        secure=secure,
        database=database,
        schema=_nonempty("schema", get(query, "schema", nothing)),
        role=_nonempty("role", get(query, "role", nothing)),
        warehouse=_nonempty("warehouse", get(query, "warehouse", nothing)),
        connect_timeout=_parse_duration("connectTimeout", get(query, "connectTimeout", nothing),
                                        DEFAULT_CONNECT_TIMEOUT),
        timeout=_parse_duration("timeout", get(query, "timeout", nothing),
                                DEFAULT_REQUEST_TIMEOUT),
        idle_limit=_parse_duration("idleLimit", get(query, "idleLimit", nothing),
                                   DEFAULT_IDLE_LIMIT),
    )
end

# Splits `host`, `host:port` or `[v6::addr]:port`. A scheme that has a port of
# its own keeps it: reading the engine's default into `https://h` would quietly
# move the DSN to another port, so only the custom scheme — which has no default
# of its own — falls back to the engine's.
function _split_authority(authority::String, scheme::String)
    fallback = scheme == "http" ? 80 : scheme == "https" ? 443 : DEFAULT_PORT
    if startswith(authority, '[')
        close = findfirst(']', authority)
        close === nothing && throw(UsageError("the DSN has an unclosed IPv6 address"))
        host = authority[2:prevind(authority, close)]
        rest = authority[nextind(authority, close):end]
        isempty(rest) && return (host, fallback)
        startswith(rest, ':') || throw(UsageError("the DSN is missing host[:port]"))
        return (host, _parse_port(rest[2:end]))
    end
    colon = findlast(':', authority)
    colon === nothing && return (authority, fallback)
    return (authority[1:prevind(authority, colon)], _parse_port(authority[nextind(authority, colon):end]))
end

function _parse_port(text::AbstractString)
    port = tryparse(Int, text)
    port === nothing &&
        throw(UsageError(string("the DSN port must be a number, got \"", text, "\"")))
    return port
end

function _parse_query(query::String)
    out = Dict{String,String}()
    isempty(query) && return out
    for pair in split(query, '&')
        isempty(pair) && continue
        eq = findfirst('=', pair)
        if eq === nothing
            out[_percent_decode(String(pair))] = ""
        else
            key = _percent_decode(String(pair[1:prevind(pair, eq)]))
            out[key] = _percent_decode(String(pair[nextind(pair, eq):end]))
        end
    end
    return out
end

function _percent_decode(text::String)
    ('%' in text || '+' in text) || return text
    buf = IOBuffer()
    bytes = codeunits(text)
    i = 1
    n = length(bytes)
    while i <= n
        c = bytes[i]
        if c == UInt8('%') && i + 2 <= n
            high = _hexdigit(bytes[i + 1])
            low = _hexdigit(bytes[i + 2])
            if high >= 0 && low >= 0
                write(buf, UInt8(high * 16 + low))
                i += 3
                continue
            end
        end
        write(buf, c == UInt8('+') ? UInt8(' ') : c)
        i += 1
    end
    return String(take!(buf))
end

function _nonempty(name::String, value)
    value === nothing && return nothing
    isempty(value) && throw(UsageError(string("the DSN parameter ", name, " cannot be empty")))
    return String(value)
end

function _parse_bool(name::String, value::AbstractString)
    folded = lowercase(String(value))
    (folded == "true" || folded == "1" || folded == "yes") && return true
    (folded == "false" || folded == "0" || folded == "no") && return false
    throw(UsageError(string(name, " must be true or false, got \"", value, "\"")))
end

const _DURATION_PATTERN = r"^(\d+(?:\.\d+)?)(ms|s|m|h)?$"

"""
Reads a duration written the way a connection string writes one: a bare number
of seconds, or a number with an `ms`/`s`/`m`/`h` suffix. Zero is meaningful — it
removes the bound — so it is accepted where a negative number is not.
"""
function _parse_duration(name::String, value, fallback::Float64)
    value === nothing && return fallback
    m = match(_DURATION_PATTERN, strip(String(value)))
    m === nothing &&
        throw(UsageError(string(name, " must be a duration such as 30s, 500ms or 5m, got \"",
                                value, "\"")))
    amount = parse(Float64, m[1])
    unit = m[2] === nothing ? "s" : String(m[2])
    factor = unit == "ms" ? 0.001 : unit == "m" ? 60.0 : unit == "h" ? 3600.0 : 1.0
    return amount * factor
end

"""
    _seconds(value) -> Float64

Normalises a timeout given as a number of seconds or as a `Dates.Period`, so
both `timeout = 30` and `timeout = Dates.Minute(5)` mean what they look like.
"""
_seconds(value::Real) = Float64(value)
_seconds(value::Dates.FixedPeriod) = Dates.value(Dates.Nanosecond(value)) / 1e9
# A month or a year has no fixed length, so it names no timeout.
_seconds(value::Dates.Period) =
    throw(UsageError(string("a timeout must be a fixed-length period, got ", value)))
_seconds(::Nothing) = nothing
