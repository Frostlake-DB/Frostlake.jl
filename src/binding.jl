# Client-side parameter binding.
#
# The HTTP protocol has no server-side binding, so parameters are inlined here
# with the same rules Frostlake's JDBC driver uses. The scan that finds bind
# sites is shared by counting and substitution, so the two cannot disagree about
# what is a placeholder.

const _QUESTION = UInt8('?')
const _COLON = UInt8(':')
const _EQUALS = UInt8('=')
const _RPAREN = UInt8(')')
const _RBRACKET = UInt8(']')
const _RBRACE = UInt8('}')

"""
    Placeholder

One bind site in a statement: a positional `?` (`name === nothing`) or a
`:name`. `start` is the index of the first byte of the marker and `stop` the
index just past it.
"""
struct Placeholder
    start::Int
    stop::Int
    name::Union{String,Nothing}
end

"""
    scan_placeholders(sql) -> Vector{Placeholder}

Finds every bind site in a statement, skipping string literals, quoted
identifiers, dollar-quoted bodies and comments.
"""
function scan_placeholders(sql::String)
    out = Placeholder[]
    bytes = codeunits(sql)
    n = length(bytes)
    i = 1
    while i <= n
        skip = skip_enclosure(sql, i)
        if skip > 0
            i = skip
            continue
        end
        c = bytes[i]
        if c == _QUESTION
            push!(out, Placeholder(i, i + 1, nothing))
            i += 1
            continue
        end
        if c != _COLON
            i += 1
            continue
        end
        # `::` is a cast and `:=` an assignment; neither introduces a parameter.
        if i + 1 <= n
            nxt = bytes[i + 1]
            if nxt == _COLON || nxt == _EQUALS
                i += 2
                continue
            end
        end
        # A colon ADJACENT to the end of an expression — an identifier
        # character, `)`, `]`, `}`, `"` or `'` — is Snowflake's VARIANT path
        # access (`v:field`, `PARSE_JSON('...'):k`, `{'a': 1}:a`, `"V":k`), not a
        # parameter: a bind marker follows an operator, comma or keyword
        # boundary instead.
        if i > 1
            prev = bytes[i - 1]
            if iswordchar(prev) || prev == _RPAREN || prev == _RBRACKET ||
               prev == _RBRACE || prev == _DOUBLE_QUOTE || prev == _APOSTROPHE
                i += 1
                continue
            end
        end
        j = i + 1
        while j <= n && iswordchar(bytes[j])
            j += 1
        end
        # A leading digit means a positional reference (`:1`), not a name.
        first = j > i + 1 ? bytes[i + 1] : 0x00
        if j > i + 1 && !(UInt8('0') <= first <= UInt8('9'))
            push!(out, Placeholder(i, j, uppercase(sql[(i + 1):(j - 1)])))
            i = j
            continue
        end
        i += 1
    end
    return out
end

"""
    placeholder_count(sql) -> Int

How many arguments a statement expects. Named placeholders count once each
however often they appear. A statement mixing the two styles reports `-1`, so a
caller checking the count leaves the real complaint to the substitution.
"""
function placeholder_count(sql::String)
    positional = 0
    names = Set{String}()
    for p in scan_placeholders(sql)
        if p.name === nothing
            positional += 1
        else
            push!(names, p.name)
        end
    end
    positional > 0 && !isempty(names) && return -1
    return isempty(names) ? positional : length(names)
end

"""
    placeholder_names(sql) -> Vector{String}

The parameter names a statement carries, upper-cased, in order of first
appearance.
"""
function placeholder_names(sql::String)
    out = String[]
    seen = Set{String}()
    for p in scan_placeholders(sql)
        p.name === nothing && continue
        p.name in seen && continue
        push!(seen, p.name)
        push!(out, p.name)
    end
    return out
end

"""
    substitute_positional(sql, parameters) -> String

Inlines positional `?` placeholders with formatted literals. With no arguments at
all the `?` marks pass through to the server — they are what a Snowflake
Scripting cursor placeholder looks like, bound by `OPEN c USING (...)`; with
arguments the count has to match exactly.
"""
function substitute_positional(sql::String, parameters)
    sites = scan_placeholders(sql)
    named = count(p -> p.name !== nothing, sites)
    if named > 0 && length(sites) != named
        throw(UsageError("a statement may use ? or :name placeholders, not both"))
    end
    if named > 0
        # With no arguments at all, the colon references are the SERVER's —
        # Snowflake Scripting variables (`EXECUTE IMMEDIATE :v`, `IFF(:flag,
        # ...)`) — and the statement passes through verbatim. Named client binds
        # exist only when named arguments are supplied.
        isempty(parameters) && return sql
        throw(UsageError("the statement uses :name placeholders; " *
                         "pass a dictionary of named parameters instead of a vector"))
    end
    # Symmetrically, with no arguments at all the ? marks are the SERVER's — a
    # Snowflake Scripting cursor placeholder bound by `OPEN c USING (...)` — and the
    # statement passes through verbatim. Positional client binds exist only when
    # arguments are supplied.
    isempty(parameters) && return sql
    if length(sites) != length(parameters)
        throw(UsageError(string("the statement has ", length(sites),
                                " placeholder(s), got ", length(parameters),
                                " argument(s)")))
    end
    isempty(sites) && return sql
    return _render(sql, sites, (site, index) -> format_literal(parameters[index]))
end

"""
    substitute_named(sql, parameters) -> String

Inlines `:name` placeholders with formatted literals. Names match
case-insensitively and their order does not matter. An argument that no
placeholder mentions is an error rather than a silent no-op — it almost always
means the name was misspelled on one side or the other.
"""
function substitute_named(sql::String, parameters::AbstractDict)
    sites = scan_placeholders(sql)
    positional = count(p -> p.name === nothing, sites)
    if positional > 0 && length(sites) != positional
        throw(UsageError("a statement may use ? or :name placeholders, not both"))
    end
    if positional > 0
        throw(UsageError("the statement uses positional ? placeholders; " *
                         "pass a vector of parameters instead of a dictionary"))
    end
    values = Dict{String,Any}()
    for (key, value) in parameters
        values[uppercase(string(key))] = value
    end
    if isempty(sites)
        isempty(values) && return sql
        throw(UsageError(string("the statement has no placeholders, got ",
                                length(values), " named argument(s)")))
    end
    used = Set{String}()
    rendered = _render(sql, sites, function (site, _)
        name = site.name::String
        haskey(values, name) ||
            throw(UsageError(string("no argument bound for :", lowercase(name))))
        push!(used, name)
        return format_literal(values[name])
    end)
    unused = sort!([k for k in keys(values) if !(k in used)])
    if !isempty(unused)
        throw(UsageError(string("argument(s) ",
                                join([string(":", lowercase(n)) for n in unused], ", "),
                                " do not appear in the statement")))
    end
    return rendered
end

function _render(sql::String, sites::Vector{Placeholder}, literal_for)
    buf = IOBuffer()
    # Byte spans, not `SubString`: a marker may sit directly after a multi-byte
    # character, and its last byte is not an index `String` will slice at.
    bytes = codeunits(sql)
    cursor = 1
    for (index, site) in enumerate(sites)
        site.start > cursor && write(buf, @view bytes[cursor:(site.start - 1)])
        write(buf, literal_for(site, index))
        cursor = site.stop
    end
    cursor <= length(bytes) && write(buf, @view bytes[cursor:end])
    return String(take!(buf))
end

"""
    format_literal(value) -> String

Renders a Julia value as the SQL literal that stands in for it.

| Julia value | SQL literal |
| --- | --- |
| `nothing`, `missing` | `NULL` |
| `Bool` | `TRUE` / `FALSE` |
| `Integer` (`Int`, `BigInt`, ...) | the digits, exactly; a negative in parentheses |
| `AbstractFloat` | the shortest round-tripping form; NaN and the infinities cast from text |
| `AbstractString` | `'...'`, backslashes and quotes escaped |
| `Vector{UInt8}` | `X'hex'` |
| `Date` | `'...'::DATE` |
| `Time` | `'...'::TIME` |
| `DateTime` | `'...'::TIMESTAMP_NTZ` — a Julia `DateTime` names no zone |
| `ZonedTimestamp` | `'...'::TIMESTAMP_TZ`, carrying its offset |
| `AbstractVector` | `[...]`, elements formatted recursively |
| `AbstractDict` | `{'key': ...}`, values formatted recursively |
"""
function format_literal end

format_literal(::Nothing) = "NULL"
format_literal(::Missing) = "NULL"
format_literal(value::Bool) = value ? "TRUE" : "FALSE"
format_literal(value::Integer) = _numeral(string(value))

function format_literal(value::AbstractFloat)
    # Julia spells these NaN, Inf and -Inf, which the parser reads as
    # identifiers. Cast from text they are the engine's own spellings — the
    # shorter 'Inf' is refused.
    isnan(value) && return "'NaN'::FLOAT"
    value == Inf && return "'Infinity'::FLOAT"
    value == -Inf && return "'-Infinity'::FLOAT"
    return _numeral(string(Float64(value)))
end

# A negative numeral goes in parentheses: spliced straight after a minus it would
# otherwise open a `--` comment, so `SELECT 3-?` bound -5 became `SELECT 3--5`,
# which the engine reads as `SELECT 3`.
_numeral(text::String) = startswith(text, "-") ? string("(", text, ")") : text

format_literal(value::AbstractString) = encode_string_literal(value)

# `Vector{UInt8}` is Julia's bytes type and the deliberate marker for binary
# data; a `Vector{Int}` is an array of numbers. Snowflake has both, and guessing
# between them from the element type would make `[1, 2, 3]` mean two different
# things.
format_literal(value::AbstractVector{UInt8}) = string("X'", _hex(value), "'")

# Not `Dates.format`, whose `yyyy` keeps only the last four digits: a year past
# 9999 would silently name another one, and the engine's calendar stops there.
function format_literal(value::Dates.Date)
    _check_year(Dates.year(value))
    return string("'", _pad(Dates.year(value), 4), "-", _pad(Dates.month(value), 2), "-",
                  _pad(Dates.day(value), 2), "'::DATE")
end
format_literal(value::Dates.Time) = string("'", format_time(value), "'::TIME")

# A Julia `DateTime` is a wall clock with no zone of its own, which is exactly
# what TIMESTAMP_NTZ is. Casting to TIMESTAMP_TZ here would invent an offset the
# value never carried.
format_literal(value::Dates.DateTime) =
    string("'", format_naive(value), "'::TIMESTAMP_NTZ")

# The engine prints an offset as `+0100` but only parses `+01:00`, which is what
# `format_zoned` writes.
format_literal(value::ZonedTimestamp) =
    string("'", format_zoned(value), "'::TIMESTAMP_TZ")

format_literal(value::AbstractVector) =
    string("[", join((format_literal(element) for element in value), ", "), "]")

function format_literal(value::AbstractDict)
    parts = String[]
    for key in sort!(collect(keys(value)); by=string)
        if !(key isa AbstractString || key isa Symbol)
            throw(UsageError(string("an object key must be a string, got ", typeof(key))))
        end
        push!(parts, string(encode_string_literal(string(key)), ": ",
                            format_literal(value[key])))
    end
    return string("{", join(parts, ", "), "}")
end

format_literal(value) = throw(UsageError(string("unsupported bind type ", typeof(value))))

"""
    encode_string_literal(text) -> String

Mirrors the engine's canonical literal encoder: backslashes doubled (a backslash
always escapes), quotes doubled.
"""
encode_string_literal(text::AbstractString) =
    string("'", replace(String(text), "\\" => "\\\\", "'" => "''"), "'")

_hex(bytes) = uppercase(join(string(b; base=16, pad=2) for b in bytes))
