using Test
using IFEdd
using IMASdd
using JSON

# the extended lattice lockfile drift gate + GeneratorError coverage for the
# `derive_abstracts` walker. The byte-equality test runs first so that
# any drift between committed `abstracts.json` and live derivation
# fails fast with an actionable message before downstream tests see
# divergent state.

const EXTRAS_DIR = joinpath(pkgdir(IFEdd), "data_dictionary",
                            "data_structures_extra")
const COMMITTED_JSON = joinpath(pkgdir(IFEdd), "data_dictionary",
                                "abstracts.json")

@testset "abstracts derivation" begin

    @testset "abstracts.json byte-equality vs live derivation" begin
        @test isfile(COMMITTED_JSON)
        lattice = IFEdd.derive_abstracts(EXTRAS_DIR)
        fresh = IFEdd.format_abstracts_json(lattice.abstracts, lattice.default_concretes)
        committed = read(COMMITTED_JSON, String)
        if fresh != committed
            @error """
            abstracts.json drift FAILED.

            The committed lockfile at
                $(COMMITTED_JSON)
            differs from `IFEdd.derive_abstracts` output.

            To fix:
                julia --project scripts/derive_abstracts.jl
                git add data_dictionary/abstracts.json
                git commit
            """
        end
        @test fresh == committed
    end

    @testset "derived lattice has exactly 13 entries" begin
        # 8 abstracts. adds 5 shared
        # (AbstractIDS{Code, CodeLibrary, Properties, PropertiesPlugins,
        # PropertiesProvenance}). Each shared abstract hosts 3 paths
        # (summary/build/driver), but lattice keys are still per-abstract.
        lattice = IFEdd.derive_abstracts(EXTRAS_DIR)
        @test length(lattice.abstracts) == 13
        @test length(lattice.default_concretes) == 13
        # Shared abstracts: inner dict has 3 entries
        @test length(lattice.default_concretes["AbstractIDSCode"]) == 3
        @test length(lattice.default_concretes["AbstractIDSCodeLibrary"]) == 3
        @test length(lattice.default_concretes["AbstractIDSProperties"]) == 3
        # Per-IDS abstracts: inner dict has 1 entry
        @test length(lattice.default_concretes["AbstractIFESummary"]) == 1
        @test length(lattice.default_concretes["AbstractIFEBuildLayer"]) == 1
    end

    @testset ":conflicting_marker — same path, different abstract" begin
        td = mktempdir()
        write(joinpath(td, "a.json"), JSON.json(Dict(
            "build.layer" => Dict("_supertype" => "AbstractIFEBuildLayer",
                                  "data_type" => "STRUCT_ARRAY",
                                  "documentation" => "x"),
        )))
        write(joinpath(td, "b.json"), JSON.json(Dict(
            "build.layer" => Dict("_supertype" => "AbstractIFEDifferent",
                                  "data_type" => "STRUCT_ARRAY",
                                  "documentation" => "y"),
        )))
        err = try IFEdd.derive_abstracts(td); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :conflicting_marker
    end

    @testset ":parent_mismatch — same abstract with two parent classes" begin
        td = mktempdir()
        write(joinpath(td, "a.json"), JSON.json(Dict(
            "build.layer" => Dict("_supertype" => "AbstractIFESameAbs",
                                  "data_type" => "STRUCT_ARRAY",
                                  "documentation" => "x"),
            "build.layer[:].outline" => Dict("_supertype" => "AbstractIFESameAbs",
                                              "data_type" => "STRUCTURE",
                                              "documentation" => "y"),
        )))
        err = try IFEdd.derive_abstracts(td); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :parent_mismatch
    end

    @testset "same abstract on two distinct paths IS VALID (shared)" begin
        # same abstract at multiple paths
        # produces a SHARED abstract with a multi-entry inner dict —
        # previously raised :duplicate_default; now valid.
        td = mktempdir()
        write(joinpath(td, "a.json"), JSON.json(Dict(
            "summary.target" => Dict("_supertype" => "AbstractIFEReused",
                                     "data_type" => "STRUCTURE",
                                     "documentation" => "x"),
            "build.layer[:].outline" => Dict("_supertype" => "AbstractIFEReused",
                                              "data_type" => "STRUCTURE",
                                              "documentation" => "y"),
        )))
        lattice = IFEdd.derive_abstracts(td)
        # Shared abstract registered with both default concretes:
        @test haskey(lattice.default_concretes, "AbstractIFEReused")
        inner = lattice.default_concretes["AbstractIFEReused"]
        @test length(inner) == 2
        @test inner["summary"] == "summary__target"
        @test inner["build"]   == "build__layer___outline"
    end

    @testset ":bad_marker_placement — marker on leaf data_type" begin
        td = mktempdir()
        write(joinpath(td, "a.json"), JSON.json(Dict(
            "summary.target.gain" => Dict("_supertype" => "AbstractIFESummaryTargetGain",
                                           "data_type" => "FLT_0D",
                                           "documentation" => "leaf"),
        )))
        err = try IFEdd.derive_abstracts(td); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :bad_marker_placement
    end

    @testset ":bad_marker_placement — marker on .time leaf-base" begin
        td = mktempdir()
        write(joinpath(td, "a.json"), JSON.json(Dict(
            "summary.time" => Dict("_supertype" => "AbstractIFETime",
                                    "data_type" => "FLT_1D_TYPE",
                                    "documentation" => "time"),
        )))
        err = try IFEdd.derive_abstracts(td); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :bad_marker_placement
    end

    @testset ":bad_marker_value — empty / non-identifier" begin
        td = mktempdir()
        write(joinpath(td, "a.json"), JSON.json(Dict(
            "x.y" => Dict("_supertype" => "",
                          "data_type" => "STRUCTURE",
                          "documentation" => "empty"),
        )))
        err = try IFEdd.derive_abstracts(td); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :bad_marker_value

        td2 = mktempdir()
        write(joinpath(td2, "a.json"), JSON.json(Dict(
            "x.y" => Dict("_supertype" => "1starts-with-digit",
                          "data_type" => "STRUCTURE",
                          "documentation" => "bad id"),
        )))
        err2 = try IFEdd.derive_abstracts(td2); nothing catch e; e end
        @test err2 isa IFEdd.GeneratorError
        @test err2.reason === :bad_marker_value
    end

    @testset ":schema_dir_missing — derive against non-existent dir" begin
        err = try IFEdd.derive_abstracts(joinpath(tempname(), "nope")); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :schema_dir_missing
    end

    @testset ":malformed_json — derive against broken file" begin
        td = mktempdir()
        write(joinpath(td, "broken.json"), "not JSON {")
        err = try IFEdd.derive_abstracts(td); nothing catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :malformed_json
    end

    @testset "non-AbstractIFE prefix warns but does not error" begin
        td = mktempdir()
        write(joinpath(td, "a.json"), JSON.json(Dict(
            "x.y" => Dict("_supertype" => "MyOwnAbstract",
                          "data_type" => "STRUCTURE",
                          "documentation" => "different prefix"),
        )))
        lattice = @test_logs (:warn, r"AbstractIFE") IFEdd.derive_abstracts(td)
        @test length(lattice.abstracts) == 1
        @test haskey(lattice.abstracts, "MyOwnAbstract")
    end

end
