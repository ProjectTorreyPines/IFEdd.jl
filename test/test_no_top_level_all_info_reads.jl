using Test
using IFEdd

# Greps every `.jl` under `IFEdd/src/` for `_all_info[...]` reads that
# appear OUTSIDE a function body (i.e. at module top level). Such reads
# happen at module-load time, before `__init__()` has populated entries
# for downstream packages — they break cross-package load order
# (`MyUserPackage` types not registered before IFEdd reads them).
#
# Implementation note (Critique 1 G11): pure grep + allow-list. Trades
# false-positive risk (comments containing `_all_info[`) for zero
# dependencies on a Julia source parser. Add such lines to
# `EXPECTED_TOP_LEVEL_ALL_INFO_LINES` if they ever appear.

const EXPECTED_TOP_LEVEL_ALL_INFO_LINES = String[]

"""
    has_top_level_all_info_read(file::AbstractString) -> Vector{Tuple{Int,String}}

Returns offending `(line_number, line_text)` pairs from `file`. A line
is "offending" iff it matches the read pattern AND is not on the
allow-list. Indented matches are assumed to live inside a function
body and are skipped (matches the convention that top-level reads are
column-0).
"""
function has_top_level_all_info_read(file::AbstractString)
    offenders = Tuple{Int,String}[]
    isfile(file) || return offenders
    for (i, line) in enumerate(eachline(file))
        # Skip lines whose first non-whitespace character is `#` (comments)
        stripped = strip(line)
        startswith(stripped, "#") && continue
        # Pattern: bare `_all_info[` not in a comment. Module-qualified
        # forms (`IMASdd._all_info[`) caught too, intentionally.
        occursin(r"_all_info\s*\[", line) || continue
        # Indented matches are assumed inside a function body. Top-level
        # reads in this codebase are always column-0.
        startswith(line, " ") && continue
        startswith(line, "\t") && continue
        # Inside `function ... end` blocks counts as not-top-level. We do
        # not parse here; rely on indentation convention.
        line in EXPECTED_TOP_LEVEL_ALL_INFO_LINES && continue
        push!(offenders, (i, line))
    end
    return offenders
end

@testset "no top-level _all_info reads in IFEdd source" begin
    src_dir = joinpath(pkgdir(IFEdd), "src")
    @test isdir(src_dir)
    all_offenders = Pair{String,Vector{Tuple{Int,String}}}[]
    for (root, _, files) in walkdir(src_dir)
        for f in files
            endswith(f, ".jl") || continue
            path = joinpath(root, f)
            offenders = has_top_level_all_info_read(path)
            isempty(offenders) || push!(all_offenders,
                                        relpath(path, src_dir) => offenders)
        end
    end
    if !isempty(all_offenders)
        for (rel, hits) in all_offenders
            @info "Top-level _all_info read detected" file=rel hits=hits
        end
    end
    @test isempty(all_offenders)
end
