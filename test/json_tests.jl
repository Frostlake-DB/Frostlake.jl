using Test
using Frostlake: json_decode, json_encode, JSONNumber, JSONUndefined, JSONParseError,
                 isintegral, asint, asbig, asfloat, aswhole, UsageError

@testset "json" begin
    @testset "scalars" begin
        @test json_decode("null") === nothing
        @test json_decode("true") === true
        @test json_decode("false") === false
        @test json_decode("\"text\"") == "text"
        @test json_decode("  \n\t 7 ") isa JSONNumber
        @test json_decode("[]") == []
        @test json_decode("{}") == Dict{String,Any}()
    end

    @testset "structure" begin
        decoded = json_decode("""{"a": [1, {"b": null}], "c": "x"}""")
        @test decoded isa Dict{String,Any}
        @test decoded["c"] == "x"
        @test decoded["a"][2]["b"] === nothing
        @test json_decode("[[[1]]]")[1][1][1].text == "1"
    end

    @testset "numbers keep their text" begin
        # The whole reason this parser exists: a NUMBER(38,0) is exact on the
        # wire and must not be rounded on the way in.
        big = json_decode("12345678901234567890123456789012345678")
        @test big.text == "12345678901234567890123456789012345678"
        @test asint(big) === nothing
        @test asbig(big) == big"12345678901234567890123456789012345678"
        @test isintegral(big)

        small = json_decode("-42")
        @test asint(small) == -42
        @test asfloat(small) == -42.0

        fractional = json_decode("3.500")
        @test !isintegral(fractional)
        @test asint(fractional) === nothing
        @test asbig(fractional) === nothing
        @test asfloat(fractional) == 3.5
        @test fractional.text == "3.500"

        @test json_decode("1e3").text == "1e3"
        @test !isintegral(json_decode("1e3"))
        @test asfloat(json_decode("-1.5E-3")) == -0.0015
    end

    @testset "string escapes" begin
        @test json_decode("\"a\\nb\"") == "a\nb"
        @test json_decode("\"\\\"\\\\\\/\"") == "\"\\/"
        @test json_decode("\"\\b\\f\\r\\t\"") == "\b\f\r\t"
        @test json_decode("\"\\u0041\\u00e9\"") == "Aé"
        # Outside the BMP, as a surrogate pair.
        @test json_decode("\"\\ud83d\\ude00\"") == "😀"
        # A lone surrogate is not a character; the rest of the value survives.
        @test json_decode("\"a\\ud800b\"") == "a\ufffdb"
        # Multi-byte text passes through untouched.
        @test json_decode("\"żółw 😀\"") == "żółw 😀"
    end

    @testset "tolerates what an engine may still emit" begin
        # Not JSON, but Snowflake's semi-structured model has them, and losing a
        # whole response over one cell would be worse.
        @test json_decode("undefined") isa JSONUndefined
        @test json_decode("[1, undefined]")[2] isa JSONUndefined
        @test isnan(json_decode("NaN"))
        @test json_decode("Infinity") == Inf
        @test json_decode("-Infinity") == -Inf
    end

    @testset "malformed input is reported" begin
        @test_throws JSONParseError json_decode("")
        @test_throws JSONParseError json_decode("{")
        @test_throws JSONParseError json_decode("\"unterminated")
        @test_throws JSONParseError json_decode("{\"a\" 1}")
        @test_throws JSONParseError json_decode("[1,]")
        @test_throws JSONParseError json_decode("1 2")
        @test_throws JSONParseError json_decode("\"\\q\"")
        @test_throws JSONParseError json_decode("\"\\u12\"")
        @test_throws JSONParseError json_decode("1.")
        @test_throws JSONParseError json_decode("tru")
    end

    @testset "encoding" begin
        @test json_encode(nothing) == "null"
        @test json_encode(missing) == "null"
        @test json_encode(true) == "true"
        @test json_encode(7) == "7"
        @test json_encode(big"123456789012345678901234567890") == "123456789012345678901234567890"
        @test json_encode(1.5) == "1.5"
        @test json_encode("plain") == "\"plain\""
        @test json_encode("a\"b\\c") == "\"a\\\"b\\\\c\""
        @test json_encode("line\nfeed\ttab") == "\"line\\nfeed\\ttab\""
        @test json_encode("bell\a") == "\"bell\\u0007\""
        @test json_encode([1, "a", nothing]) == "[1,\"a\",null]"
        # Sorted members, so the same value always encodes to the same text.
        @test json_encode(Dict("b" => 1, "a" => 2)) == "{\"a\":2,\"b\":1}"
        @test json_encode(Dict(:sym => [true])) == "{\"sym\":[true]}"
        @test_throws UsageError json_encode(NaN)
        @test_throws UsageError json_encode(Inf)
        @test_throws UsageError json_encode(:symbol)
    end

    @testset "round trip" begin
        for text in ("{\"sql\":\"SELECT 'it''s' FROM t -- ?\\n\"}",
                     "{\"a\":[1,2,{\"b\":\"żółw\"}]}")
            @test json_encode(json_decode(text)) == text
        end
    end

    @testset "whole numbers in other spellings" begin
        # An engine that produces BigDecimals writes a whole value as `1E+3` or
        # `12.000`; an integral column still reads it exactly.
        @test aswhole(JSONNumber("42")) === 42
        @test aswhole(JSONNumber("123456789012345678901234567890")) ==
              big"123456789012345678901234567890"
        @test aswhole(JSONNumber("1E+3")) === 1000
        @test aswhole(JSONNumber("1.2E+5")) === 120000
        @test aswhole(JSONNumber("12.000")) === 12
        @test aswhole(JSONNumber("-1.50E+1")) === -15
        @test aswhole(JSONNumber("0E-3")) === 0
        @test aswhole(JSONNumber("1E+30")) == big"1000000000000000000000000000000"
        @test aswhole(JSONNumber("1E+30")) isa BigInt
        # Genuinely fractional, or wider than any NUMBER: not a whole number.
        @test aswhole(JSONNumber("12.5")) === nothing
        @test aswhole(JSONNumber("5E-3")) === nothing
        @test aswhole(JSONNumber("1E+100")) === nothing
        @test aswhole(JSONNumber("1E+99999999999999999999")) === nothing
    end

    @testset "a missing separator is reported where it was expected" begin
        @test_throws JSONParseError json_decode("{\"a\":1 \"b\":2}")
        @test_throws JSONParseError json_decode("[1 2]")
        err = try
            json_decode("[1 2]")
        catch e
            e
        end
        @test startswith(sprint(showerror, err), "JSONParseError: ")
        @test occursin("at offset", sprint(showerror, err))
    end

    @testset "less common escapes and values" begin
        # A high surrogate without its low half keeps both escapes, the lone half
        # as the replacement character.
        @test json_decode("\"\\uD83D\\u0041\"") == "�A"
        @test json_encode("a\rb\bc\fd") == "\"a\\rb\\bc\\fd\""
        @test json_encode(JSONUndefined()) == "null"
        @test sprint(show, JSONNumber("1.50")) == "1.50"
    end
end
