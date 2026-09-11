# Lexical helpers shared by parameter binding and session-scope tracking.
#
# Both need to walk a statement while stepping over the places where SQL syntax
# stops meaning what it says — string literals, quoted identifiers,
# dollar-quoted bodies and comments — so both read the same scanner and cannot
# disagree about what is inside one.
#
# Positions are byte offsets into the statement, which is what a Julia `String`
# indexes by. Every position handed to the multi-byte searches below sits just
# after an ASCII delimiter, so it is always a valid character boundary.

const _TAB = UInt8('\t')
const _LF = UInt8('\n')
const _CR = UInt8('\r')
const _SPACE = UInt8(' ')
const _DOLLAR = UInt8('$')
const _APOSTROPHE = UInt8('\'')
const _STAR = UInt8('*')
const _MINUS = UInt8('-')
const _SLASH = UInt8('/')
const _SEMICOLON = UInt8(';')
const _UNDERSCORE = UInt8('_')
const _DOUBLE_QUOTE = UInt8('"')
const _BACKSLASH = UInt8('\\')

"Whether `c` can appear in an unquoted identifier."
iswordchar(c::UInt8) =
    c == _UNDERSCORE || c == _DOLLAR ||
    (UInt8('a') <= c <= UInt8('z')) ||
    (UInt8('A') <= c <= UInt8('Z')) ||
    (UInt8('0') <= c <= UInt8('9'))

isspacechar(c::UInt8) = c == _SPACE || c == _TAB || c == _LF || c == _CR

"""
    skip_string(sql, i) -> Int

The index just past the single-quoted literal starting at `i`. Both `''` and
backslash escapes end up inside the literal — a backslash always escapes in
Frostlake's string dialect.
"""
function skip_string(sql::String, i::Int)
    bytes = codeunits(sql)
    j = i + 1
    n = length(bytes)
    while j <= n
        c = bytes[j]
        if c == _BACKSLASH
            j += 2  # a backslash always escapes
        elseif c == _APOSTROPHE
            if j + 1 <= n && bytes[j + 1] == _APOSTROPHE
                j += 2
            else
                return j + 1
            end
        else
            j += 1
        end
    end
    return j
end

"The index just past the double-quoted identifier starting at `i`."
function skip_quoted(sql::String, i::Int)
    bytes = codeunits(sql)
    j = i + 1
    n = length(bytes)
    while j <= n
        if bytes[j] == _DOUBLE_QUOTE
            if j + 1 <= n && bytes[j + 1] == _DOUBLE_QUOTE
                j += 2
                continue
            end
            return j + 1
        end
        j += 1
    end
    return j
end

"""
    opens_dollar_quote(sql, i) -> Bool

Whether the `\$` at `i` opens a dollar-quoted body. A `\$` is legal inside an
unquoted identifier, so `A\$\$B` is a name rather than the start of a body: a
real delimiter is never preceded by an identifier character.
"""
function opens_dollar_quote(sql::String, i::Int)
    bytes = codeunits(sql)
    (i + 1 <= length(bytes) && bytes[i + 1] == _DOLLAR) || return false
    return i == 1 || !iswordchar(bytes[i - 1])
end

"""
    skip_dollar_quoted(sql, i) -> Int

The index just past the dollar-quoted body starting at `i`. Function and
procedure bodies are written this way, and their contents are not SQL — a `?`
inside one is part of the body, never a placeholder.
"""
function skip_dollar_quoted(sql::String, i::Int)
    stop = findnext("\$\$", sql, i + 2)
    return stop === nothing ? ncodeunits(sql) + 1 : last(stop) + 1
end

"The index just past the line comment starting at `i`."
function skip_line(sql::String, i::Int)
    stop = findnext("\n", sql, i)
    return stop === nothing ? ncodeunits(sql) + 1 : last(stop) + 1
end

"The index just past the block comment starting at `i`."
function skip_block_comment(sql::String, i::Int)
    stop = findnext("*/", sql, i + 2)
    return stop === nothing ? ncodeunits(sql) + 1 : last(stop) + 1
end

"""
    skip_enclosure(sql, i) -> Int

Whether a comment or a quoted region opens at `i`, and where it ends: the index
just past the region, or `0` when `i` does not open one. Every walk over a
statement starts here, so none of them can forget a case.
"""
function skip_enclosure(sql::String, i::Int)
    bytes = codeunits(sql)
    n = length(bytes)
    c = bytes[i]
    if c == _APOSTROPHE
        return skip_string(sql, i)
    elseif c == _DOUBLE_QUOTE
        return skip_quoted(sql, i)
    elseif c == _DOLLAR
        return opens_dollar_quote(sql, i) ? skip_dollar_quoted(sql, i) : 0
    elseif c == _MINUS
        return (i + 1 <= n && bytes[i + 1] == _MINUS) ? skip_line(sql, i) : 0
    elseif c == _SLASH
        if i + 1 <= n
            nxt = bytes[i + 1]
            nxt == _SLASH && return skip_line(sql, i)
            nxt == _STAR && return skip_block_comment(sql, i)
        end
        return 0
    end
    return 0
end

"""
    split_statements(sql) -> Vector{String}

Splits a request on its top-level semicolons, leaving alone any that sit inside
a string literal, a quoted identifier, a dollar-quoted body or a comment.

A procedural block is split along with everything else, which only makes the
scope check below more willing to flag — the safe direction.
"""
function split_statements(sql::String)
    out = String[]
    bytes = codeunits(sql)
    n = length(bytes)
    start = 1
    i = 1
    while i <= n
        skip = skip_enclosure(sql, i)
        if skip > 0
            i = skip
            continue
        end
        if bytes[i] == _SEMICOLON
            push!(out, _slice(bytes, start, i - 1))
            start = i + 1
        end
        i += 1
    end
    push!(out, _slice(bytes, start, n))
    return out
end

# Cuts a span of bytes out of a statement.
#
# Not `sql[from:to]`: these bounds are byte offsets found by scanning for ASCII
# delimiters, and the byte before a delimiter may be the tail of a multi-byte
# character — which `String` indexing refuses rather than slices. Every span cut
# here begins and ends on a boundary the scanner established, so the bytes are
# what to copy.
_slice(bytes, from::Int, to::Int) = to < from ? "" : String(@view bytes[from:to])

"""
    changes_session_scope(sql) -> Bool

Whether a request can move the session off the scope the DSN established.

A request may hold more than one statement, and a `USE` riding behind a leading
`SELECT` moves the scope just as surely as one standing alone, so every
statement is examined rather than only the first.
"""
changes_session_scope(sql::String) = any(_statement_changes_scope, split_statements(sql))

# Only `USE`, the `SET` family, `ALTER SESSION`, and `CREATE`/`DROP` of a
# `DATABASE` or `SCHEMA` move the session — `CREATE TABLE` and its kind leave
# the scope exactly where it was, and counting those would mark the session
# dirty for every DDL statement a caller runs.
function _statement_changes_scope(statement::AbstractString)
    words = leading_words(String(statement), 6)
    isempty(words) && return false
    verb = words[1]
    if verb == "USE" || verb == "SET" || verb == "UNSET"
        return true
    elseif verb == "ALTER"
        return _names_object(words[2:end], ("SESSION",))
    elseif verb == "CREATE" || verb == "DROP"
        return _names_object(words[2:end], ("DATABASE", "SCHEMA"))
    end
    return false
end

# Modifiers that may sit between CREATE/DROP/ALTER and the kind of object being
# named.
const _OBJECT_MODIFIERS = ("OR", "REPLACE", "TRANSIENT", "TEMPORARY", "TEMP",
                           "VOLATILE", "LOCAL", "GLOBAL", "SECURE", "IF", "NOT",
                           "EXISTS")

# Walks the words between the verb and the object being named, stepping over the
# modifiers that may sit between them — `CREATE OR REPLACE DATABASE`, `DROP
# SCHEMA IF EXISTS` — and reports whether the object is one of `want`.
function _names_object(words, want)
    for word in words
        word in _OBJECT_MODIFIERS && continue
        return word in want
    end
    return false
end

"""
    leading_words(statement, n) -> Vector{String}

Up to `n` words from the start of a statement, upper-cased, skipping whitespace
and comments and stopping at the first thing that is not a word.
"""
function leading_words(statement::String, n::Int)
    out = String[]
    bytes = codeunits(statement)
    len = length(bytes)
    i = 1
    while i <= len && length(out) < n
        c = bytes[i]
        if isspacechar(c)
            i += 1
            continue
        end
        # Only comments are stepped over here: a leading string literal or
        # quoted identifier means the statement does not start with a keyword at
        # all.
        if c == _MINUS || c == _SLASH
            skip = skip_enclosure(statement, i)
            if skip > 0
                i = skip
                continue
            end
        end
        iswordchar(c) || return out
        start = i
        while i <= len && iswordchar(bytes[i])
            i += 1
        end
        push!(out, uppercase(statement[start:(i - 1)]))
    end
    return out
end
