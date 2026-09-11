# Turning wire cells into Julia values, guided by the column's declared type.
#
# The engine renders temporals, binary and semi-structured values as text and
# numbers as bare JSON numbers, so the declared type is what says how to read
# them back.

"""
    ZonedTimestamp

A `TIMESTAMP_TZ` / `TIMESTAMP_LTZ` value: a wall clock together with the offset
it was written at.

Julia's standard library has no zoned type — a `DateTime` is a wall clock with
nowhere to keep an offset — and folding the offset in would lose it, so the two
halves are kept side by side. `utc(z)` gives the instant, which is what to
compare two of these by; `z.datetime` gives the local reading, which is what the
engine prints.

```julia
z = ZonedTimestamp(DateTime(2024, 1, 15, 10, 30), Dates.Second(3600))
utc(z)  # 2024-01-15T09:30:00
```
"""
struct ZonedTimestamp
    "The wall clock, as read at `offset`."
    datetime::Dates.DateTime
    "How far `datetime` runs ahead of UTC."
    offset::Dates.Second
end

ZonedTimestamp(datetime::Dates.DateTime) = ZonedTimestamp(datetime, Dates.Second(0))

"""
    utc(z::ZonedTimestamp) -> DateTime

The instant `z` names, as a UTC wall clock. Two `ZonedTimestamp`s written at
different offsets are the same moment when their `utc` agree.
"""
utc(z::ZonedTimestamp) = z.datetime - z.offset

Base.show(io::IO, z::ZonedTimestamp) = print(io, "ZonedTimestamp(", format_zoned(z), ")")

# The engine's binary floating-point types. Every other numeric it reports is
# fixed-point.
const APPROXIMATE_TYPES = Set(["FLOAT", "FLOAT4", "FLOAT8", "DOUBLE",
                               "DOUBLE PRECISION", "REAL"])

# The whole-number types that carry no scale of their own.
const INTEGER_TYPES = Set(["INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT",
                           "BYTEINT"])

# The fixed-point types, whose scale decides whether they hold whole numbers.
const FIXED_POINT_TYPES = Set(["NUMBER", "NUMERIC", "DECIMAL"])

"""
    base_type_name(datatype) -> String

Strips any `(p,s)` suffix, so `NUMBER(38,0)` and `NUMBER` answer alike.
"""
function base_type_name(datatype)
    name = uppercase(strip(datatype === nothing ? "" : String(datatype)))
    open = findfirst('(', name)
    return open === nothing ? name : strip(name[1:prevind(name, open)])
end

"""
    temporal_kind(datatype) -> Symbol

Which temporal shape, if any, a declared type names: `:date`, `:time`, `:naive`
(a wall clock with no zone of its own), `:zoned`, or `:none`.
"""
function temporal_kind(datatype)
    name = base_type_name(datatype)
    name == "DATE" && return :date
    name == "TIME" && return :time
    (name == "TIMESTAMP" || name == "TIMESTAMP_NTZ" || name == "DATETIME") && return :naive
    (name == "TIMESTAMP_LTZ" || name == "TIMESTAMP_TZ") && return :zoned
    return :none
end

function is_binary_type(datatype)
    name = base_type_name(datatype)
    return name == "BINARY" || name == "VARBINARY"
end

"""
    declared_scale(column) -> Int

The column's scale, preferring the wire's own field and falling back to an
inline `NUMBER(p,s)` spelling for servers that put both in the type name.
"""
function declared_scale(column::ColumnInfo)
    scale = column.scale
    (scale !== nothing && scale != 0) && return scale
    name = column.datatype
    open = findfirst('(', name)
    comma = findfirst(',', name)
    close = findfirst(')', name)
    if open !== nothing && comma !== nothing && close !== nothing &&
       comma > open && close > comma
        parsed = tryparse(Int, strip(name[nextind(name, comma):prevind(name, close)]))
        parsed === nothing || return parsed
    end
    return scale === nothing ? 0 : scale
end

"""
    is_integral_column(column) -> Bool

Whether a column holds whole numbers. The wire carries precision and scale as
their own fields — `datatype` is the bare word `NUMBER` — so scale is what
decides, with an inline `NUMBER(p,s)` spelling honoured as a fallback.
"""
function is_integral_column(column::ColumnInfo)
    name = base_type_name(column.datatype)
    name in INTEGER_TYPES && return true
    name in FIXED_POINT_TYPES && return declared_scale(column) == 0
    return false
end

"""
    convert_cell(raw, column) -> Any

Maps one decoded JSON cell to a Julia value.

Temporals become `Date`, `Time`, `DateTime` or [`ZonedTimestamp`](@ref),
`BINARY` a `Vector{UInt8}`, integral numerics an `Int64` — or a `BigInt` past 64
bits — and everything approximate or fractional a `Float64`. `VARIANT`, `OBJECT`
and `ARRAY` arrive as the engine's own text rendering.
"""
function convert_cell(raw, column::ColumnInfo)
    raw === nothing && return nothing
    # A VARIANT `undefined` standing alone is SQL NULL: the sentinel exists
    # inside an ARRAY and never leaks into scalar evaluation.
    raw isa JSONUndefined && return nothing
    raw isa Bool && return raw
    if raw isa AbstractString
        kind = temporal_kind(column.datatype)
        if kind !== :none
            parsed = parse_temporal(String(raw), kind)
            return parsed === nothing ? String(raw) : parsed
        end
        if is_binary_type(column.datatype)
            decoded = decode_hex(String(raw))
            return decoded === nothing ? String(raw) : decoded
        end
        if base_type_name(column.datatype) in APPROXIMATE_TYPES
            special = float_special(raw)
            special === nothing || return special
        end
        return String(raw)
    end
    raw isa JSONNumber && return _convert_number(raw, column)
    # The engine renders semi-structured values as text, so these only appear if
    # a server takes to sending them structurally. Handing back the JSON text
    # keeps the column reading the same either way.
    (raw isa AbstractVector || raw isa AbstractDict) && return json_encode(raw)
    return raw
end

function _convert_number(number::JSONNumber, column::ColumnInfo)
    name = base_type_name(column.datatype)
    name in APPROXIMATE_TYPES && return asfloat(number)
    if is_integral_column(column) || !_is_numeric_type(name)
        # Exact at any width. A NUMBER(38,0) holds values no Int64 can name, and
        # a Float64 would silently round them away — including one the engine
        # spelled `1E+3` or `12.000`, which is a whole number all the same.
        whole = aswhole(number)
        whole === nothing || return whole
    end
    return asfloat(number)
end

"""
    float_special(text) -> Union{Float64,Nothing}

The engine renders a non-finite double as the JSON *string* `NaN`, `Infinity` or
`-Infinity`, even on a FLOAT column; on such a column that text reads back as the
double it names. Anything else is `nothing`.
"""
function float_special(text::AbstractString)
    lowered = lowercase(strip(text))
    lowered == "nan" && return NaN
    lowered in ("inf", "+inf", "infinity", "+infinity") && return Inf
    lowered in ("-inf", "-infinity") && return -Inf
    return nothing
end

_is_numeric_type(name) =
    name in INTEGER_TYPES || name in FIXED_POINT_TYPES || name in APPROXIMATE_TYPES

# ---------------------------------------------------------------- temporals

const _DATE_PATTERN = r"^(\d{4,})-(\d{2})-(\d{2})$"
const _TIME_PATTERN = r"^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?$"
const _NAIVE_PATTERN = r"^(\d{4,})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?$"
const _ZONED_PATTERN =
    r"^(\d{4,}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s*(Z|[+-]\d{2}:?\d{2})$"

"""
    parse_temporal(text, kind) -> Any

Reads a temporal cell, or `nothing` when the text does not parse as one — in
which case the caller keeps the text, since a value the caller can still read
beats one the driver threw away.
"""
function parse_temporal(text::String, kind::Symbol)
    try
        return _parse_temporal(text, kind)
    catch e
        # `Dates` refuses an out-of-range field — `24:00:00`, a 30th of February
        # — with an ArgumentError; the contract here is "keep the text".
        e isa ArgumentError || rethrow()
        return nothing
    end
end

function _parse_temporal(text::String, kind::Symbol)
    kind === :date && return parse_date(text)
    kind === :time && return parse_time(text)
    kind === :naive && return parse_naive(text)
    if kind === :zoned
        zoned = parse_zoned(text)
        zoned === nothing || return zoned
        # An engine that renders a zoned column without an offset still names a
        # wall clock, so read it as one rather than discarding the value.
        naive = parse_naive(text)
        return naive === nothing ? nothing : ZonedTimestamp(naive)
    end
    return nothing
end

function parse_date(text::String)
    m = match(_DATE_PATTERN, strip(text))
    m === nothing && return nothing
    return Dates.Date(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]))
end

"""
    parse_time(text) -> Union{Time,Nothing}

Reads a `TIME` cell. Julia's `Time` holds nanoseconds, which is finer than
anything the wire carries, so nothing is lost here.
"""
function parse_time(text::String)
    m = match(_TIME_PATTERN, strip(text))
    m === nothing && return nothing
    ms, us, ns = _fraction_parts(m[4])
    return Dates.Time(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]), ms, us, ns)
end

"""
    parse_naive(text) -> Union{DateTime,Nothing}

Reads a `TIMESTAMP_NTZ`-style cell. A Julia `DateTime` holds milliseconds, which
is what the HTTP layer carries; a finer fraction is truncated, since there is
nowhere in a `DateTime` to keep it.
"""
function parse_naive(text::String)
    m = match(_NAIVE_PATTERN, strip(text))
    m === nothing && return nothing
    ms, _, _ = _fraction_parts(m[7])
    return Dates.DateTime(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]),
                          parse(Int, m[4]), parse(Int, m[5]), parse(Int, m[6]), ms)
end

"""
    parse_zoned(text) -> Union{ZonedTimestamp,Nothing}

Reads a `TIMESTAMP_TZ` / `TIMESTAMP_LTZ` cell. The engine writes its offset as
`+0100`, and other spellings (`+01:00`, `Z`) are accepted too.
"""
function parse_zoned(text::String)
    m = match(_ZONED_PATTERN, strip(text))
    m === nothing && return nothing
    local_time = parse_naive(String(m[1]))
    local_time === nothing && return nothing
    zone = String(m[2])
    zone == "Z" && return ZonedTimestamp(local_time, Dates.Second(0))
    digits = replace(zone, ":" => "")
    hours = parse(Int, digits[2:3])
    minutes = parse(Int, digits[4:5])
    seconds = hours * 3600 + minutes * 60
    return ZonedTimestamp(local_time, Dates.Second(startswith(digits, "-") ? -seconds : seconds))
end

# Splits a fractional-seconds group into the milli/micro/nanosecond fields Julia
# builds temporals from, padding a short fraction and dropping anything finer
# than a nanosecond.
function _fraction_parts(digits)
    (digits === nothing || isempty(digits)) && return (0, 0, 0)
    padded = length(digits) >= 9 ? String(digits)[1:9] : rpad(String(digits), 9, '0')
    return (parse(Int, padded[1:3]), parse(Int, padded[4:6]), parse(Int, padded[7:9]))
end

"""
    decode_hex(text) -> Union{Vector{UInt8},Nothing}

Decodes the hex text the engine renders `BINARY` as, or `nothing` when the text
is not hex after all.

Anything else is not the driver's to reinterpret: silently dropping a stray
character would turn a value the caller can still read into one they cannot.
"""
function decode_hex(text::String)
    isempty(text) && return UInt8[]
    bytes = codeunits(text)
    isodd(length(bytes)) && return nothing
    out = Vector{UInt8}(undef, length(bytes) >> 1)
    for i in eachindex(out)
        high = _hexdigit(bytes[2i - 1])
        low = _hexdigit(bytes[2i])
        (high < 0 || low < 0) && return nothing
        out[i] = UInt8(high * 16 + low)
    end
    return out
end

# ---------------------------------------------------------------- rendering

"Renders a `Time` the way a `TIME` literal is written."
function format_time(value::Dates.Time)
    base = string(_pad(Dates.hour(value), 2), ":", _pad(Dates.minute(value), 2),
                  ":", _pad(Dates.second(value), 2))
    fraction = Dates.millisecond(value) * 1_000_000 +
               Dates.microsecond(value) * 1_000 + Dates.nanosecond(value)
    fraction == 0 && return base
    return string(base, ".", rstrip(_pad(fraction, 9), '0'))
end

"Renders a `DateTime` the way a `TIMESTAMP_NTZ` literal is written."
function format_naive(value::Dates.DateTime)
    _check_year(Dates.year(value))
    base = string(_pad(Dates.year(value), 4), "-", _pad(Dates.month(value), 2), "-",
                  _pad(Dates.day(value), 2), " ", _pad(Dates.hour(value), 2), ":",
                  _pad(Dates.minute(value), 2), ":", _pad(Dates.second(value), 2))
    return string(base, ".", _pad(Dates.millisecond(value), 3))
end

"""
    format_zoned(value) -> String

Renders a [`ZonedTimestamp`](@ref) with a `+HH:MM` offset — the spelling the
engine parses. It prints `+0100` without the colon, and reads both.
"""
function format_zoned(value::ZonedTimestamp)
    total = Dates.value(value.offset)
    sign = total < 0 ? "-" : "+"
    total = abs(total)
    return string(format_naive(value.datetime), " ", sign,
                  _pad(total ÷ 3600, 2), ":", _pad((total % 3600) ÷ 60, 2))
end

_pad(value::Integer, width::Int) = lpad(string(value), width, '0')

# The engine's calendar runs from year 1 to 9999; padded to four digits, a year
# outside it would silently name a different one.
_check_year(year::Integer) = 1 <= year <= 9999 ||
    throw(UsageError(string("a date's year must fall within 1..9999, got ", year)))
