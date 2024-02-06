using StaticLint: run_lint_on_text, comp
import CSTParser
using Test

function lint_test(source::String, expected_substring::String, verbose=true)
    io = IOBuffer()
    run_lint_on_text(source; io=io)
    output = String(take!(io))
    result = contains(output, expected_substring)
    verbose && !result && @warn "Not matching " output expected_substring
    return result
end

function lint_has_error_test(source::String, verbose=false)
    io = IOBuffer()
    run_lint_on_text(source; io=io)
    result = String(take!(io))
    all_lines = split(result, "\n")

    verbose && @info result
    # We remove decorations
    return any(l->startswith(l, "Line "), all_lines)
end

@testset "interface" begin
    source = "1 + 2 \n 1 + 10 \n true || true\n10"
    @test lint_has_error_test(source)
    @test lint_test(source,
        "Line 3, column 3: The first argument of a `||` call is a boolean literal. at offset 17 of")
end

@testset "forbidden macros" begin
    @testset "@async" begin
        source = """
            function f()
                @async 1 + 2
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 2, column 5: Macro @spawn should be used instead of @async.")
    end
end

@testset "forbidden functions" begin
    @testset "nthreads()" begin
        source = """
            function f()
                return Threads.nthreads()
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 2, column 12: Threads.nthreads() should not be used.")
    end
end

@testset "Comparison" begin
    @test comp(CSTParser.parse("Threads.nthreads()"), CSTParser.parse("Threads.nthreads()"))
    @test !comp(CSTParser.parse("QWEThreads.nthreads()"), CSTParser.parse("Threads.nthreads()"))
    @test !comp(CSTParser.parse("Threads.nthreads()"), CSTParser.parse("QWEThreads.nthreads()"))

    @test comp(CSTParser.parse("1 + 2"), CSTParser.parse("1 + 2"))
    @test comp(CSTParser.parse("1 + 2"), CSTParser.parse("1 + hole_variable"))
    @test comp(CSTParser.parse("hole_variable + hole_variable"), CSTParser.parse("1 + hole_variable"))
    @test comp(CSTParser.parse("hole_variable + 1"), CSTParser.parse("1 + hole_variable"))

    @test comp(CSTParser.parse("@async hole_variable"), CSTParser.parse("@async begin 1 + 2 end"))
end