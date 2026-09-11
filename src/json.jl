# A JSON reader and writer, written here rather than taken from a package.
#
# Julia ships no JSON parser, and the one thing this driver needs from one is
# unusual enough to be worth owning: a NUMBER(38,0) holds integers no Float64
# can name, and the engine sends them as bare JSON numbers. A parser that
# resolves numbers while scanning has already rounded them away by the time the
# column's declared type is known, so numbers are kept as their literal text
# (`JSONNumber`) and turned into an Int64, a BigInt or a Float64 later, once
# `values.jl` knows what the column actually is.
#
# Keeping it in the package also means `import Frostlake` pulls in nothing but
# the standard library.

"""
    JSONNumber

A JSON number as it was written, before anything decided what kind of number it
is. `text` is the literal, exactly as it arrived.
"""
struct JSONNumber
    text::String
end

"""
    JSONUndefined

The bare `undefined` token. Not JSON, but Snowflake's semi-structured model has
a value that is neither null nor present, and a parser that died on it would
lose a whole response over one cell. It reads back as SQL NULL.
"""
struct JSONUndefined end

"""
    JSONParseError

The text was not JSON. Raised by [`json_decode`](@ref); the connection layer
turns it into a `ConnectionError` naming the endpoint that produced it, which is
the difference between "malformed JSON at offset 0" and an error naming the
address that answered.
"""
struct JSONParseError <: Exception
    message::String
    offset::Int
end

Base.showerror(io::IO, e::JSONParseError) =
    print(io, "JSONParseError: ", e.message, " at offset ", e.offset)

"Whether the literal names a whole number, so `NUMBER(38,0)` can stay exact."
isintegral(n::JSONNumber) =
    !occursin('.', n.text) && !occursin('e', n.text) && !occursin('E', n.text)

"The value as an `Int64`, or `nothing` when it does not fit one."
asint(n::JSONNumber) = isintegral(n) ? tryparse(Int64, n.text) : nothing

"The value as a `BigInt`, or `nothing` when the literal is not a whole number."
function asbig(n::JSONNumber)
    isintegral(n) || return nothing
    return tryparse(BigInt, n.text)
end

const _NUMBER_SHAPE = r"^(-)?(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$"

"""
    aswhole(n) -> Union{Int64,BigInt,Nothing}

The value as a whole number — an `Int64` when it fits, a `BigInt` otherwise — or
`nothing` when it is genuinely fractional. Unlike `asint`, this also reads the
spellings a BigDecimal-producing engine uses for whole values: `1E+3`, `1.2E+5`,
`12.000`.
"""
function aswhole(n::JSONNumber)
    if isintegral(n)
        small = asint(n)
        small === nothing || return small
        return asbig(n)
    end
    m = match(_NUMBER_SHAPE, n.text)
    m === nothing && return nothing
    negative = m[1] !== nothing
    fraction = m[3] === nothing ? "" : m[3]
    exponent = m[4] === nothing ? 0 : tryparse(Int, m[4])
    exponent === nothing && return nothing
    digits = string(m[2], fraction)
    scale = exponent - length(fraction)
    if scale < 0
        # Whole only if every digit right of the point is a zero.
        keep = length(digits) + scale
        dropped = keep <= 0 ? digits : digits[keep+1:end]
        all(==('0'), dropped) || return nothing
        digits = keep <= 0 ? "0" : digits[1:keep]
        scale = 0
    end
    # Wider than any NUMBER: not a value this reading is for.
    length(digits) + scale > 80 && return nothing
    value = parse(BigInt, digits)
    scale > 0 && (value *= BigInt(10)^scale)
    negative && (value = -value)
    return typemin(Int64) <= value <= typemax(Int64) ? Int64(value) : value
end

asfloat(n::JSONNumber) = something(tryparse(Float64, n.text), NaN)

Base.show(io::IO, n::JSONNumber) = print(io, n.text)

# ---------------------------------------------------------------- decoding

mutable struct _Reader
    bytes::Base.CodeUnits{UInt8,String}
    pos::Int
end

@inline _peek(r::_Reader) = r.pos <= length(r.bytes) ? r.bytes[r.pos] : 0x00
@inline _done(r::_Reader) = r.pos > length(r.bytes)

_fail(r::_Reader, message::AbstractString) = throw(JSONParseError(String(message), r.pos))

function _skipspace(r::_Reader)
    while !_done(r)
        c = r.bytes[r.pos]
        (c == UInt8(' ') || c == UInt8('\t') || c == UInt8('\n') || c == UInt8('\r')) || break
        r.pos += 1
    end
end

"""
    json_decode(text) -> Any

Reads one JSON document.

`null` becomes `nothing`, objects `Dict{String,Any}`, arrays `Vector{Any}`,
numbers [`JSONNumber`](@ref), and the non-standard tokens an engine may still
emit — `undefined`, `NaN`, `Infinity` — become [`JSONUndefined`](@ref) and the
`Float64` they name.
"""
function json_decode(text::AbstractString)
    r = _Reader(codeunits(String(text)), 1)
    _skipspace(r)
    value = _readvalue(r)
    _skipspace(r)
    _done(r) || _fail(r, "trailing content after the document")
    return value
end

function _readvalue(r::_Reader)
    _skipspace(r)
    _done(r) && _fail(r, "the document is empty")
    c = _peek(r)
    if c == UInt8('{')
        return _readobject(r)
    elseif c == UInt8('[')
        return _readarray(r)
    elseif c == UInt8('"')
        return _readstring(r)
    elseif c == UInt8('t')
        _expect(r, "true"); return true
    elseif c == UInt8('f')
        _expect(r, "false"); return false
    elseif c == UInt8('n')
        _expect(r, "null"); return nothing
    elseif c == UInt8('u')
        # Not JSON, but see `JSONUndefined`.
        _expect(r, "undefined"); return JSONUndefined()
    elseif c == UInt8('N')
        _expect(r, "NaN"); return NaN
    elseif c == UInt8('I')
        _expect(r, "Infinity"); return Inf
    elseif c == UInt8('-') && r.pos < length(r.bytes) && r.bytes[r.pos + 1] == UInt8('I')
        r.pos += 1
        _expect(r, "Infinity")
        return -Inf
    else
        return _readnumber(r)
    end
end

function _expect(r::_Reader, word::String)
    for c in codeunits(word)
        (!_done(r) && r.bytes[r.pos] == c) || _fail(r, string("expected ", word))
        r.pos += 1
    end
end

function _readobject(r::_Reader)
    r.pos += 1  # the opening brace
    out = Dict{String,Any}()
    _skipspace(r)
    if _peek(r) == UInt8('}')
        r.pos += 1
        return out
    end
    while true
        _skipspace(r)
        _peek(r) == UInt8('"') || _fail(r, "expected a member name")
        key = _readstring(r)
        _skipspace(r)
        _peek(r) == UInt8(':') || _fail(r, "expected a colon after a member name")
        r.pos += 1
        out[key] = _readvalue(r)
        _skipspace(r)
        c = _peek(r)
        if c == UInt8(',')
            r.pos += 1
        elseif c == UInt8('}')
            r.pos += 1
            return out
        else
            _fail(r, "expected a comma or a closing brace in an object")
        end
    end
end

function _readarray(r::_Reader)
    r.pos += 1  # the opening bracket
    out = Any[]
    _skipspace(r)
    if _peek(r) == UInt8(']')
        r.pos += 1
        return out
    end
    while true
        push!(out, _readvalue(r))
        _skipspace(r)
        c = _peek(r)
        if c == UInt8(',')
            r.pos += 1
        elseif c == UInt8(']')
            r.pos += 1
            return out
        else
            _fail(r, "expected a comma or a closing bracket in an array")
        end
    end
end

function _readstring(r::_Reader)
    r.pos += 1  # opening quote
    buf = IOBuffer()
    start = r.pos
    while true
        _done(r) && _fail(r, "the string is not closed")
        c = r.bytes[r.pos]
        if c == UInt8('"')
            r.pos > start && write(buf, @view r.bytes[start:(r.pos - 1)])
            r.pos += 1
            return String(take!(buf))
        elseif c == UInt8('\\')
            r.pos > start && write(buf, @view r.bytes[start:(r.pos - 1)])
            r.pos += 1
            _readescape(r, buf)
            start = r.pos
        else
            r.pos += 1
        end
    end
end

function _readescape(r::_Reader, buf::IOBuffer)
    _done(r) && _fail(r, "the escape is not finished")
    c = r.bytes[r.pos]
    r.pos += 1
    if c == UInt8('"')
        write(buf, UInt8('"'))
    elseif c == UInt8('\\')
        write(buf, UInt8('\\'))
    elseif c == UInt8('/')
        write(buf, UInt8('/'))
    elseif c == UInt8('b')
        write(buf, UInt8('\b'))
    elseif c == UInt8('f')
        write(buf, UInt8('\f'))
    elseif c == UInt8('n')
        write(buf, UInt8('\n'))
    elseif c == UInt8('r')
        write(buf, UInt8('\r'))
    elseif c == UInt8('t')
        write(buf, UInt8('\t'))
    elseif c == UInt8('u')
        code = _readhex4(r)
        # A character outside the BMP arrives as a surrogate pair; the two
        # halves are meaningless apart, so the low half is read here rather
        # than written out as its own (invalid) character.
        if 0xD800 <= code <= 0xDBFF && r.pos + 1 <= length(r.bytes) &&
           r.bytes[r.pos] == UInt8('\\') && r.bytes[r.pos + 1] == UInt8('u')
            r.pos += 2
            low = _readhex4(r)
            if 0xDC00 <= low <= 0xDFFF
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            else
                # Not a pair after all: keep both, as the text had them.
                print(buf, _safechar(code))
                code = low
            end
        end
        print(buf, _safechar(code))
    else
        _fail(r, "unknown escape")
    end
end

# A lone surrogate is not a character; U+FFFD keeps the rest of the value
# readable instead of failing the whole response over one cell.
_safechar(code::Integer) = (0xD800 <= code <= 0xDFFF) ? Char(0xFFFD) : Char(code)

function _readhex4(r::_Reader)
    r.pos + 3 <= length(r.bytes) || _fail(r, "a unicode escape needs four hex digits")
    code = 0
    for _ in 1:4
        digit = _hexdigit(r.bytes[r.pos])
        digit < 0 && _fail(r, "a unicode escape needs four hex digits")
        code = code * 16 + digit
        r.pos += 1
    end
    return code
end

function _hexdigit(c::UInt8)
    if UInt8('0') <= c <= UInt8('9')
        return Int(c - UInt8('0'))
    elseif UInt8('a') <= c <= UInt8('f')
        return Int(c - UInt8('a')) + 10
    elseif UInt8('A') <= c <= UInt8('F')
        return Int(c - UInt8('A')) + 10
    end
    return -1
end

function _readnumber(r::_Reader)
    start = r.pos
    _peek(r) == UInt8('-') && (r.pos += 1)
    _digits(r) || _fail(r, "expected a number")
    if _peek(r) == UInt8('.')
        r.pos += 1
        _digits(r) || _fail(r, "expected digits after the decimal point")
    end
    c = _peek(r)
    if c == UInt8('e') || c == UInt8('E')
        r.pos += 1
        c = _peek(r)
        (c == UInt8('+') || c == UInt8('-')) && (r.pos += 1)
        _digits(r) || _fail(r, "expected digits in the exponent")
    end
    return JSONNumber(String(@view r.bytes[start:(r.pos - 1)]))
end

function _digits(r::_Reader)
    seen = false
    while !_done(r) && UInt8('0') <= r.bytes[r.pos] <= UInt8('9')
        r.pos += 1
        seen = true
    end
    return seen
end

# ---------------------------------------------------------------- encoding

"""
    json_encode(value) -> String

Writes a value back out as JSON. Object members are emitted in sorted key order,
so the same value always encodes to the same text.
"""
function json_encode(value)
    buf = IOBuffer()
    _write_json(buf, value)
    return String(take!(buf))
end

_write_json(io::IO, ::Nothing) = print(io, "null")
_write_json(io::IO, ::Missing) = print(io, "null")
_write_json(io::IO, ::JSONUndefined) = print(io, "null")
_write_json(io::IO, value::Bool) = print(io, value ? "true" : "false")
_write_json(io::IO, value::Integer) = print(io, string(value))
_write_json(io::IO, value::JSONNumber) = print(io, value.text)

function _write_json(io::IO, value::AbstractFloat)
    isfinite(value) || throw(UsageError(string(value, " cannot be written as JSON")))
    print(io, string(Float64(value)))
end

function _write_json(io::IO, value::AbstractString)
    write(io, UInt8('"'))
    for c in value
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif c < ' ' || c == Char(0x7F)
            print(io, "\\u", lpad(string(UInt32(c); base=16), 4, '0'))
        else
            print(io, c)
        end
    end
    write(io, UInt8('"'))
end

function _write_json(io::IO, value::AbstractDict)
    write(io, UInt8('{'))
    first = true
    for key in sort!(collect(keys(value)); by=string)
        first || write(io, UInt8(','))
        first = false
        _write_json(io, string(key))
        write(io, UInt8(':'))
        _write_json(io, value[key])
    end
    write(io, UInt8('}'))
end

function _write_json(io::IO, value::AbstractVector)
    write(io, UInt8('['))
    for (i, element) in enumerate(value)
        i == 1 || write(io, UInt8(','))
        _write_json(io, element)
    end
    write(io, UInt8(']'))
end

_write_json(io::IO, value) =
    throw(UsageError(string(typeof(value), " cannot be written as JSON")))
