using StaticLint: StaticLint, run_lint_on_text, comp, convert_offset_to_line,
    convert_offset_to_line_from_lines, should_be_filtered, MarkdownFormat, PlainFormat
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

# FOR FUTURE WORK
# @testset "string interpolation" begin
#     source = raw"""$(@async 1 + 2)"""
#     @test lint_has_error_test(source)
# end

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

    @testset "Locally disabling lint" begin
        @testset "lint-disable-lint" begin
            @test !lint_has_error_test("""
                function f()
                    @async 1 + 2 # lint-disable-line
                end
                """)
            @test !lint_has_error_test("""
                function f()
                    @async 1 + 2 #lint-disable-line
                end
                """)

            @test !lint_has_error_test("""
                function f()
                    @async 1 + 2 #  lint-disable-line
                end
                """)

            @test lint_has_error_test("""
                function f()
                    @async 1 + 2 #  lint-disable-line
                    @async 1 + 3
                end
                """)
        end
        @testset "lint-disable-next-line" begin
            @test !lint_has_error_test("""
                function f()
                    # lint-disable-next-line
                    @async 1 + 2
                end
                """)
            @test !lint_has_error_test("""
                function f()
                    # lint-disable-next-line
                    @async 1 + 2
                end
                """)

            @test !lint_has_error_test("""
                function f()
                    # lint-disable-next-line
                    @async 1 + 2
                end
                """)

            @test lint_has_error_test("""
                function f()
                    # lint-disable-next-line
                    @async 1 + 2

                    @async 1 + 3
                end
                """)
            @test lint_has_error_test("""
                function f()
                    @async 1 + 2
                    # lint-disable-next-line

                    @async 1 + 3
                end
                """)
            @test lint_has_error_test("""
                function f()
                    @async 1 + 2
                    # lint-disable-next-line
                    @async 1 + 3
                end
                """)

            source = """
                function f()
                    # lint-disable-next-line
                    @async 1 + 2

                    @async 1 + 3
                end
                """
            source_lines = split(source, "\n")
            @test convert_offset_to_line_from_lines(46, source_lines) == (3, 4, Symbol("lint-disable-line"))
            @test convert_offset_to_line_from_lines(64, source_lines) == (5, 4, nothing)
        end
    end
end

@testset "forbidden functions" begin
    @testset "nthreads() as a const" begin
        source = """
            const x = Threads.nthreads()
            function f()
                return x
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 1, column 11: Threads.nthreads() should not be used in a constant variable.")
    end

    @testset "nthreads() not as a const" begin
        source = """
            function f()
                return Threads.nthreads()
            end
            """
        @test !lint_has_error_test(source)
    end

    @testset "finalizer with do-end" begin
        source = """
            function f(x)
                ref = Ref(1)
                x = ___MutableFoo(ref)
                finalizer(x) do x
                    ref[] = 3
                end
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 4, column 5: finalize(_,_) should not be used.")

    end
    @testset "finalizer without do-end" begin
        source = """
            function f(x)
                finalizer(q->nothing, x)
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 2, column 5: finalize(_,_) should not be used.")
    end

    @testset "ccall" begin
        source = """
            function rusage(who:: RUsageWho = RUSAGE_SELF)
                ru = Vector{RUsage}(undef, 1)
                ccall(:getrusage, Cint, (Cint, Ptr{Cvoid}), who, ru)
                return ru[1]
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 3, column 5: ccall should not be used.")
    end

    @testset "ccall 02" begin
        source = """
            function _pread_async!(fd::Integer, buffer::Ptr{UInt8}, count::Integer, offset::Integer)::UInt64
                uv_filesystem_request, uv_buffer_descriptor = _prepare_libuv_async_call(buffer, count)

                ccall(:uv_fs_read, Int32,
                            (Ptr{Cvoid}, Ptr{Cvoid}, Int32, Ptr{Cvoid}, UInt32, Int64, Ptr{Cvoid}),
                            Base.eventloop(), uv_filesystem_request, fd, uv_buffer_descriptor, UInt32(1), offset,
                            @cfunction(_readwrite_cb, Cvoid, (Ptr{Cvoid}, ))
                            )
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 4, column 5: ccall should not be used.")
    end

    @testset "pointer_from_objref 01" begin
        source = """
            function f(x)
                return pointer_from_objref(v)
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 2, column 12: pointer_from_objref should not be used.")
    end

    @testset "pointer_from_objref 02" begin
        source = """
            function _reinterpret_with_size0(::Type{T1}, value::T2; checked::Bool=true) where {T1<:Tuple,T2<:Tuple}
                checked && _check_valid_reinterpret_with_size0(T1, T2)
                v = Ref(value)
                GC.@preserve v begin
                    ptr = pointer_from_objref(v)
                    return Base.unsafe_load(reinterpret(Ptr{T1}, ptr))
                end
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 5, column 15: pointer_from_objref should not be used.")
    end

    @testset "pointer_from_objref 03" begin
        source = raw"""
            function vertex_name(c::Any)
                return "v$(UInt64(pointer_from_objref(c)))"
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 2, column 23: pointer_from_objref should not be used")
    end


end

@testset "Comparison" begin
    t(s1, s2) = comp(CSTParser.parse(s1), CSTParser.parse(s2))
    @test t("Threads.nthreads()", "Threads.nthreads()")
    @test !t("QWEThreads.nthreads()", "Threads.nthreads()")
    @test !t("Threads.nthreads()", "QWEThreads.nthreads()")
    @test !t("Threads.nthreads()", "Threads.qwenthreads()")

    @test t("1 + 2", "1+2")
    @test t("1 + 2", "1+hole_variable")
    @test t("hole_variable + hole_variable", "1 + hole_variable")
    @test t("hole_variable + 1", "1 + hole_variable")

    @test t("@async hole_variable", "@async begin 1 + 2 end")

    @test t("finalizer(y, x)", "finalizer(hole_variable, hole_variable)")
    @test t("finalizer(q->nothing, x)", "finalizer(hole_variable, hole_variable)")
    @test t("finalizer(x) do hole_variable hole_variable end",
            "finalizer(x) do x
                ref[] = 3
            end")

    @test !t("foo()", "foo(hole_variable)")
    @test !t("foo()", "foo(x)")

    @test t("foo(x, y)", "foo(hole_variable, hole_variable)")
    @test !t("foo(x, y, z)", "foo(hole_variable, hole_variable)")
    @test t("foo(x, y, z)", "foo(hole_variable, hole_variable_star)")

    @test t("foo(x, y, z)", "foo(hole_variable_star)")

    # Ideally, the next line should pass.
    # @test t("foo(x, y, z)", "foo(hole_variable, hole_variable, hole_variable, hole_variable_star)")

end

@testset "offset to line" begin
    source = """
        function f()
            return Threads.nthreads()
        end
        """
    @test_throws BoundsError convert_offset_to_line(-1, source)
    @test_throws BoundsError convert_offset_to_line(length(source) + 2, source)

    @test convert_offset_to_line(10, source) == (1, 10, nothing)
    @test convert_offset_to_line(20, source) == (2, 7, nothing)
    @test convert_offset_to_line(43, source) == (2, 30, nothing)
    @test convert_offset_to_line(47, source) == (3, 4, nothing)
end

@testset "Should be filtered" begin
    filters = StaticLint.LintCodes[StaticLint.MissingReference, StaticLint.IncorrectCallArgs]
    hint_as_string1 = "Missing reference at offset 24104 of /Users/alexandrebergel/Documents/RAI/raicode11/src/DataExporter/export_csv.jl"
    hint_as_string2 = "Line 254, column 19: Possible method call error. at offset 8430 of /Users/alexandrebergel/Documents/RAI/raicode11/src/Compiler/Front/problems.jl"
    @test should_be_filtered(hint_as_string1, filters)
    @test !should_be_filtered(hint_as_string2, filters)

    @test should_be_filtered(hint_as_string1, filters)
    @test !should_be_filtered(hint_as_string2, filters)
end

@testset "Formatter" begin
    source = """
           const x = Threads.nthreads()
           function f()
               return x
           end
           """

    @testset "Plain 01" begin
        io = IOBuffer()
        run_lint_on_text(source; io=io, filters=StaticLint.no_filters)
        result = String(take!(io))

        expected = r"""
            ---------- \H+
            Line 1, column 11: Threads.nthreads\(\) should not be used in a constant variable\. at offset 10 of \H+
            Line 1, column 11: Missing reference at offset 10 of \H+
            2 potential threats are found
            ----------
            """
        @test !isnothing(match(expected, result))
    end

    @testset "Plain 02" begin
        io = IOBuffer()
        run_lint_on_text(source; io=io, filters=StaticLint.essential_filters)
        result = String(take!(io))

        expected = r"""
            ---------- \H+
            Line 1, column 11: Threads.nthreads\(\) should not be used in a constant variable\. at offset 10 of \H+
            1 potential threat is found
            ----------
            """
        @test !isnothing(match(expected, result))
    end

    @testset "Markdown 01" begin
        io = IOBuffer()
        run_lint_on_text(source; io=io, filters=StaticLint.no_filters, formatter=MarkdownFormat())
        result = String(take!(io))

        expected = r"""
             - \*\*Line 1, column 11:\*\* Threads.nthreads\(\) should not be used in a constant variable\. at offset 10 of \H+
             - \*\*Line 1, column 11:\*\* Missing reference at offset 10 of \H+
            🚨\*\*2 potential threats are found\*\*🚨
            """
        @test !isnothing(match(expected, result))
    end

    @testset "Markdown 02" begin
        io = IOBuffer()
        run_lint_on_text(source; io=io, filters=StaticLint.essential_filters, formatter=MarkdownFormat())
        result = String(take!(io))

        expected = r"""
             - \*\*Line 1, column 11:\*\* Threads.nthreads\(\) should not be used in a constant variable\. at offset 10 of \H+
            🚨\*\*1 potential threat is found\*\*🚨
            """
        @test !isnothing(match(expected, result))
    end
end

@testset "Linting multiple files" begin
    @testset "No errors" begin
        mktempdir() do dir
            open(joinpath(dir, "foo.jl"), "w") do io1
                open(joinpath(dir, "bar.jl"), "w") do io2
                    write(io1, "function f()\n  @spawn 1 + 1\nend\n")
                    write(io2, "function g()\n  @spawn 1 + 1\nend\n")

                    flush(io1)
                    flush(io2)

                    str = IOBuffer()
                    StaticLint.run_lint(dir; io=str, formatter=StaticLint.MarkdownFormat())

                    result = String(take!(str))

                    expected = r"""
                        \*\*Result of the Lint Static Analyzer (\H+) on file \H+:\*\*


                        🎉No potential threats were found.👍
                        \*\*Result of the Lint Static Analyzer (\H+) on file \H+:\*\*


                        🎉No potential threats were found.👍
                        """
                    @test !isnothing(match(expected, result))
                end
            end
        end
        @test true
    end

    @testset "Two files with errors" begin
        mktempdir() do dir
            open(joinpath(dir, "foo.jl"), "w") do io1
                open(joinpath(dir, "bar.jl"), "w") do io2
                    write(io1, "function f()\n  @async 1 + 1\nend\n")
                    write(io2, "function g()\n  @async 1 + 1\nend\n")

                    flush(io1)
                    flush(io2)

                    str = IOBuffer()
                    StaticLint.run_lint(dir; io=str, formatter=StaticLint.MarkdownFormat())

                    result = String(take!(str))

                    expected = r"""
                        \*\*Result of the Lint Static Analyzer (\H+) on file \H+:\*\*
                         - \*\*Line 2, column 3:\*\* Macro @spawn should be used instead of @async. at offset 15 of \H+


                        🚨\*\*1 potential threat is found\*\*🚨
                        \*\*Result of the Lint Static Analyzer (\H+) on file \H+:\*\*
                         - \*\*Line 2, column 3:\*\* Macro @spawn should be used instead of @async. at offset 15 of \H+


                        🚨\*\*1 potential threat is found\*\*🚨
                        """
                    @test !isnothing(match(expected, result))
                end
            end
        end
        @test true
    end
end

@testset "Running on a directory" begin
    @testset "Non empty directory" begin
        formatters = [StaticLint.PlainFormat(), StaticLint.MarkdownFormat()]
        for formatter in formatters
            mktempdir() do dir
                open(joinpath(dir, "foo.jl"), "w") do io
                    write(io, "function f()\n  @async 1 + 1\nend\n")
                    flush(io)
                    str = IOBuffer()
                    StaticLint.run_lint(dir; io=str, formatter)
                end
            end
        end
        @test true
    end

    @testset "Empty directory" begin
        mktempdir() do dir
                StaticLint.run_lint(dir)
        end
        @test true
    end
end