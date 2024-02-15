using Dates

function setup_server(env = dirname(SymbolServer.Pkg.Types.Context().env.project_file), depot = first(SymbolServer.Pkg.depots()), cache = joinpath(dirname(pathof(SymbolServer)), "..", "store"))
    server = StaticLint.FileServer()
    ssi = SymbolServerInstance(depot, cache)
    _, symbols = SymbolServer.getstore(ssi, env)
    extended_methods = SymbolServer.collect_extended_methods(symbols)
    server.external_env = ExternalEnv(symbols, extended_methods, Symbol[])
    server
end

"""
    lint_string(s, server; gethints = false)

Parse a string and run a semantic pass over it. This will mark scopes, bindings,
references, and lint hints. An annotated `EXPR` is returned or, if `gethints = true`,
it is paired with a collected list of errors/hints.
"""
function lint_string(s::String, server = setup_server(); gethints = false)
    empty!(server.files)
    f = File("", s, CSTParser.parse(s, true), nothing, server)
    env = getenv(f, server)
    setroot(f, f)
    setfile(server, "", f)
    semantic_pass(f)
    check_all(f.cst, lint_options, env)
    if gethints
        hints = []
        for (offset, x) in collect_hints(f.cst, env)
            if haserror(x)
                push!(hints, (x, LintCodeDescriptions[x.meta.error]))
                push!(hints, (x, "Missing reference", " at offset ", offset))
            end
        end
        return f.cst, hints
    else
        return f.cst
    end
end

"""
    lint_file(rootpath, server)

Read a file from disc, parse and run a semantic pass over it. The file should be the
root of a project, e.g. for this package that file is `src/StaticLint.jl`. Other files
in the project will be loaded automatically (calls to `include` with complicated arguments
are not handled, see `followinclude` for details). A `FileServer` will be returned
containing the `File`s of the package.
"""
function lint_file(rootpath, server = setup_server(); gethints = false)
    empty!(server.files)
    root = loadfile(server, rootpath)
    semantic_pass(root)
    for f in values(server.files)
        check_all(f.cst, essential_options, getenv(f, server))
    end
    if gethints
        hints = []
        for (p,f) in server.files
            hints_for_file = []
            for (offset, x) in collect_hints(f.cst, getenv(f, server))
                if haserror(x)
                    push!(hints_for_file, (x, string(LintCodeDescriptions[x.meta.error], " at offset ", offset, " of ", p)))
                    push!(hints_for_file, (x, string("Missing reference", " at offset ", offset, " of ", p)))
                end
            end
            append!(hints, hints_for_file)
        end
        return root, hints
    else
        return root
    end
end

global global_server = setup_server()
const essential_options = LintOptions(true, false, true, true, true, true, true, true, true, false, true)

const no_filters = LintCodes[]
const essential_filters = [no_filters; [StaticLint.MissingReference]]


# Return (line, column) for a given offset in a source
function convert_offset_to_line_from_filename(offset::Int64, filename::String)
    all_lines = open(io->readlines(io), filename)
    return convert_offset_to_line_from_lines(offset, all_lines)
end

function convert_offset_to_line(offset::Int64, source::String)
    return convert_offset_to_line_from_lines(offset, split(source, "\n"))
end


function convert_offset_to_line_from_lines(offset::Int64, all_lines)
    offset < 0 && throw(BoundsError("source", offset))

    current_index = 1
    annotation_previous_line = -1
    annotation = nothing
    for (index_line,line) in enumerate(all_lines)
        if endswith(line, "lint-disable-next-line")
            annotation_previous_line = index_line+1
        end

        if offset in current_index:(current_index + length(line))
            if endswith(line, "lint-disable-line") || (index_line == annotation_previous_line)
                annotation = Symbol("lint-disable-line")
            else
                annotation = nothing
            end
            result = index_line, (offset - current_index + 1), annotation
            annotation = nothing
            return result
        end
        current_index += length(line) + 1 #1 is for the Return line
    end

    throw(BoundsError("source", offset))
end

function should_be_filtered(hint_as_string::String, filters::Vector{LintCodes})
    return any(o->startswith(hint_as_string, LintCodeDescriptions[o]), filters)
end

abstract type AbstractFormatter end
struct PlainFormat <: AbstractFormatter end
struct MarkdownFormat <: AbstractFormatter end

"""
    filter_and_print_hint(hint, io::IO=stdout, filters::Vector=[])

Essential function to filter and print a `hint_as_string`, being a String.
Return true if the hint was printed, else it was filtered.
It takes the following arguments:
    - `hint_as_string` to be filtered or printed
    - `io` stream where the hint is printed, if not filtered
    - `filters` the set of filters to be used
"""
function filter_and_print_hint(hint_as_string::String, io::IO=stdout, filters::Vector{LintCodes}=LintCodes[], formatter::AbstractFormatter=PlainFormat())
    # Filter along the message
    should_be_filtered(hint_as_string, filters) && return false

    # Filter along the file content
    ss = split(hint_as_string)
    has_filename = isfile(last(ss))
    has_filename || error("Should have a filename")

    filename = string(last(ss))

    offset_as_string = ss[length(ss) - 2]
    # +1 is because CSTParser gives offset starting at 0.
    offset = Base.parse(Int64, offset_as_string) + 1

    line_number, column, annotation_line = convert_offset_to_line_from_filename(offset, filename)

    if isnothing(annotation_line)
        print_hint(formatter, io, "Line $(line_number), column $(column):", hint_as_string )
        return true
    end
    return false
end


function _run_lint_on_dir(
    rootpath::String;
    server = global_server,
    io::IO=stdout,
    filters::Vector{LintCodes}=essential_filters,
    formatter::AbstractFormatter=PlainFormat()
)
    for (root, dirs, files) in walkdir(rootpath)
        for file in files
            filename = joinpath(root, file)
            if endswith(filename, ".jl")
                run_lint(filename; server, io, filters, formatter)
            end
        end

        for dir in dirs
            _run_lint_on_dir(joinpath(root, dir); server, io, filters, formatter)
        end
    end
end

function print_header(::PlainFormat, io::IO, rootpath::String)
    printstyled(io, "-" ^ 10 * " $(rootpath)\n", color=:blue)
end

function print_hint(::PlainFormat, io::IO, coordinates::String, hint::String)
    printstyled(io, coordinates, color=:green)
    print(io, " ")
    println(io, hint)
end

function print_summary(::PlainFormat, io::IO, nb_hints::Int64)
    if iszero(nb_hints)
        printstyled(io, "No potential threats were found.\n", color=:green)
    else

        plural = nb_hints > 1 ? "s are" : " is"
        printstyled(io, "$(nb_hints) potential threat$(plural) found\n", color=:red)
    end
end

function print_footer(::PlainFormat, io::IO)
    printstyled(io, "-" ^ 10 * "\n", color=:blue)
end

function print_header(::MarkdownFormat, io::IO, rootpath::String)
    println(io, "**Result of the Lint Static Analyzer ($(now())) on file $(rootpath):**")
end

print_footer(::MarkdownFormat, io::IO) = nothing
function print_hint(::MarkdownFormat, io::IO, coordinates::String, hint::String)
    print(io, " - **$coordinates** $hint\n")
end

function print_summary(::MarkdownFormat, io::IO, nb_hints::Int64)
    println(io)
    println(io)
    if iszero(nb_hints)
        print(io, "🎉No potential threats were found.👍\n")
    else
        plural = nb_hints > 1 ? "s are" : " is"
        print(io, "🚨**$(nb_hints) potential threat$(plural) found**🚨\n")
    end
end

"""
    run_lint(rootpath::String; server = global_server, io::IO=stdout)

Run lint rules on a file `rootpath`, which must be an existing non-folder file.
Example of use:
    import StaticLint
    StaticLint.run_lint("foo/bar/myfile.jl")

"""
function run_lint(
    rootpath::String;
    server = global_server,
    io::IO=stdout,
    filters::Vector{LintCodes}=essential_filters,
    formatter::AbstractFormatter=PlainFormat()
)
    # Did we already analyzed this file? If yes, then exit.
    rootpath in keys(server.files) && return

    # If we are running Lint on a directory
    isdir(rootpath) && return _run_lint_on_dir(rootpath; server, io, filters, formatter)

    # Check if we have to be run on a Julia file. Simply exit if not.
    # This simplify the amount of work in GitHub Action
    endswith(rootpath, ".jl") || return

    # We are running Lint on a Julia file
    _,hints = StaticLint.lint_file(rootpath, server; gethints = true)

    print_header(formatter, io, rootpath)

    filtered_and_printed_hints = filter(h->filter_and_print_hint(h[2], io, filters, formatter), hints)

    print_summary(formatter, io, length(filtered_and_printed_hints))
    print_footer(formatter, io)
end

function run_lint_on_text(
    source::String;
    server = global_server,
    io::IO=stdout,
    filters::Vector{LintCodes}=essential_filters,
    formatter::AbstractFormatter=PlainFormat()
)
    tmp_file_name = tempname() * ".jl"
    open(tmp_file_name, "w") do file
        write(file, source)
        flush(file)
        run_lint(tmp_file_name; server, io, filters, formatter)
    end
end