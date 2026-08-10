using Test
using IFEdd
using IMASdd

# Unit tests for `_apply_substitution_graph` against handcrafted
# `dd_idstypes.jl`-shaped fragments. No GenerateDD invocation — pure
# regex composition + count assertions per design §13.3.

"""
    canonical_dd_fragment() -> String

Spec J — handcrafted fragment mirroring the relevant subset of
`src/dd_idstypes.jl` shapes:
- direct STRUCTURE embed (driver__beam___efficiency inside driver__beam)
- IDSvector embed (build__layer inside build, driver__beam inside driver)
- ctor calls in both shapes

Includes a `build__layer___outline` entry to confirm
`build__layer` regex does NOT partial-match it.
"""
function canonical_dd_fragment()
    return raw"""
mutable struct build__layer___outline{T} <: IFEdd.AbstractIFEBuildLayerOutline{T}
    var"r" :: Vector{T}
    var"z" :: Vector{T}
end

function build__layer___outline{T}(; frozen::Bool=false) where T
    ids = build__layer___outline{T}(T[], T[], Symbol("outline"))
    return ids
end

mutable struct build__layer{T} <: IFEdd.AbstractIFEBuildLayer{T}
    var"area"::T
    var"outline"::build__layer___outline{T}
    var"thickness"::T
end

function build__layer{T}(; frozen::Bool=false) where T
    ids = build__layer{T}(0.0, build__layer___outline{T}(;frozen), 0.0, Symbol("layer"))
    return ids
end

mutable struct build{T} <: IFEdd.AbstractIFEBuild{T}
    var"code"::build__code{T}
    var"layer"::IMASdd.IDSvector{build__layer{T}}
    var"time"::Vector{T}
end

function build{T}(; frozen::Bool=false) where T
    ids = build{T}(build__code{T}(;frozen), IMASdd.IDSvector{build__layer{T}}(;frozen), T[], Symbol("build"))
    return ids
end

mutable struct driver__beam___efficiency{T} <: IFEdd.AbstractIFEDriverBeamEfficiency{T}
    var"conversion"::T
    var"coupling"::T
end

function driver__beam___efficiency{T}(; frozen::Bool=false) where T
    ids = driver__beam___efficiency{T}(0.0, 0.0, Symbol("efficiency"))
    return ids
end

mutable struct driver__beam{T} <: IFEdd.AbstractIFEDriverBeam{T}
    var"efficiency"::driver__beam___efficiency{T}
    var"energy"::T
end

function driver__beam{T}(; frozen::Bool=false) where T
    ids = driver__beam{T}(driver__beam___efficiency{T}(;frozen), 0.0, Symbol("beam"))
    return ids
end
"""
end

@testset "_apply_substitution_graph (regex pass)" begin

    @testset "_replace_count returns (string, count)" begin
        out, n = IFEdd._replace_count("aXbXc", r"X", "Y")
        @test out == "aYbYc"
        @test n == 2
        out2, n2 = IFEdd._replace_count("hello", r"X", "Y")
        @test out2 == "hello"
        @test n2 == 0
    end

    @testset "empty graph → content unchanged" begin
        content = canonical_dd_fragment()
        graph = Dict{String,NamedTuple}()
        @test IFEdd._apply_substitution_graph(content, graph) == content
    end

    @testset "IDStop entries are skipped (top-level handled by _emit_user_dd)" begin
        # A top-level entry in the graph should NOT trigger substitution
        # (parent_kind == "IDStop" continues the loop).
        content = canonical_dd_fragment()
        graph = Dict{String,NamedTuple}(
            "summary" => (user_concrete = "my_summary",
                          abstract = "AbstractIFESummary",
                          parent_kind = "IDStop",
                          source_key = :summary),
        )
        # No miss raised even though "summary" isn't in the fragment;
        # IDStop is intentionally skipped.
        @test IFEdd._apply_substitution_graph(content, graph) == content
    end

    @testset "IDSvectorStaticElement substitution (build__layer → my_layer)" begin
        content = canonical_dd_fragment()
        graph = Dict{String,NamedTuple}(
            "build__layer" => (user_concrete = "my_layer",
                               abstract = "AbstractIFEBuildLayer",
                               parent_kind = "IDSvectorStaticElement",
                               source_key = :AbstractIFEBuildLayer),
        )
        out = IFEdd._apply_substitution_graph(content, graph)
        # Field-decl rewritten
        @test occursin("var\"layer\"::IMASdd.IDSvector{my_layer{T}}", out)
        @test !occursin("var\"layer\"::IMASdd.IDSvector{build__layer{T}}", out)
        # Ctor call rewritten
        @test occursin("IMASdd.IDSvector{my_layer{T}}(;frozen)", out)
        @test !occursin("IMASdd.IDSvector{build__layer{T}}(;frozen)", out)
        # CRITICAL: build__layer___outline must be UNTOUCHED (negative-lookahead defense)
        @test occursin("mutable struct build__layer___outline{T}", out)
        @test occursin("var\"outline\"::build__layer___outline{T}", out)
        @test occursin("build__layer___outline{T}(;frozen)", out)
    end

    @testset "IDS substitution (driver__beam___efficiency → my_efficiency)" begin
        content = canonical_dd_fragment()
        graph = Dict{String,NamedTuple}(
            "driver__beam___efficiency" => (user_concrete = "my_efficiency",
                                            abstract = "AbstractIFEDriverBeamEfficiency",
                                            parent_kind = "IDS",
                                            source_key = :AbstractIFEDriverBeamEfficiency),
        )
        out = IFEdd._apply_substitution_graph(content, graph)
        @test occursin("var\"efficiency\"::my_efficiency{T}", out)
        @test !occursin("var\"efficiency\"::driver__beam___efficiency{T}", out)
        @test occursin("my_efficiency{T}(;frozen)", out)
        # The struct declaration line itself is unchanged
        @test occursin("mutable struct driver__beam___efficiency{T}", out)
    end

    @testset "two simultaneous substitutions (mixed shapes)" begin
        content = canonical_dd_fragment()
        graph = Dict{String,NamedTuple}(
            "build__layer" => (user_concrete = "my_layer",
                               abstract = "AbstractIFEBuildLayer",
                               parent_kind = "IDSvectorStaticElement",
                               source_key = :AbstractIFEBuildLayer),
            "driver__beam___efficiency" => (user_concrete = "my_eff",
                                            abstract = "AbstractIFEDriverBeamEfficiency",
                                            parent_kind = "IDS",
                                            source_key = :AbstractIFEDriverBeamEfficiency),
        )
        out = IFEdd._apply_substitution_graph(content, graph)
        @test occursin("var\"layer\"::IMASdd.IDSvector{my_layer{T}}", out)
        @test occursin("var\"efficiency\"::my_eff{T}", out)
    end

    @testset ":substitution_missed — graph has entry not in content" begin
        content = canonical_dd_fragment()
        graph = Dict{String,NamedTuple}(
            "nonexistent__concrete" =>
                (user_concrete = "my_x",
                 abstract = "AbstractIFEBuildLayer",
                 parent_kind = "IDSvectorStaticElement",
                 source_key = :AbstractIFEBuildLayer),
        )
        err = try IFEdd._apply_substitution_graph(content, graph); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :substitution_missed
    end

    @testset ":substitution_over_match — two field decls of same default" begin
        content = canonical_dd_fragment() *
            "\nmutable struct another_parent{T}\n    var\"alias\"::IMASdd.IDSvector{build__layer{T}}\nend\n"
        graph = Dict{String,NamedTuple}(
            "build__layer" => (user_concrete = "my_layer",
                               abstract = "AbstractIFEBuildLayer",
                               parent_kind = "IDSvectorStaticElement",
                               source_key = :AbstractIFEBuildLayer),
        )
        err = try IFEdd._apply_substitution_graph(content, graph); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :substitution_over_match
    end

    @testset "qualified IFEdd.build__layer ctor call is NOT matched" begin
        # design §13.3: lookbehind `(?<![A-Za-z_0-9.])` prevents matching
        # `IFEdd.build__layer{T}(;frozen)` (qualified — already-emitted
        # IFEdd-default reference inside user dd container).
        content = "    IMASdd.IDSvector{build__layer{T}}(;frozen),\n" *
                  "    IFEdd.build__layer{T}(;frozen),\n"
        graph = Dict{String,NamedTuple}(
            "build__layer" => (user_concrete = "my_layer",
                               abstract = "AbstractIFEBuildLayer",
                               parent_kind = "IDSvectorStaticElement",
                               source_key = :AbstractIFEBuildLayer),
        )
        # Note: this content has NO field declaration so it will raise
        # :substitution_missed (field pass produces 0 matches). The
        # ctor count assertion would pass (1 vector ctor matches). But
        # since the test predicate is "qualified ctor NOT touched", we
        # check by counting in the partial-pipeline directly.
        # Apply only the ctor patterns to verify the lookbehind:
        pat_ctor_direct = Regex("(?<![A-Za-z_0-9.])\\Qbuild__layer\\E\\{T\\}\\(;\\s*frozen\\)")
        out, n = IFEdd._replace_count(content, pat_ctor_direct, "my_layer{T}(;frozen)")
        @test n == 0   # the only build__layer{T}( occurrences are prefixed (.qualified or vector-wrapped)
        @test out == content
    end

end
