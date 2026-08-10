using Test
using IFEdd
using IMASdd
using JSON

# For every entry in `abstracts.json`, assert that the corresponding
# IFEdd default concrete is emitted with the correct supertype. The
# complement test asserts that *un-annotated* STRUCTURE nodes are
# left with `<: IMASdd.IDS{T}` (or `<: IMASdd.IDSvectorStaticElement{T}`
# for STRUCT_ARRAY) — i.e. the override pass did NOT over-substitute.

const ABS_JSON   = joinpath(pkgdir(IFEdd), "data_dictionary", "abstracts.json")
const EXTRAS_DIR = joinpath(pkgdir(IFEdd), "data_dictionary",
                            "data_structures_extra")

@testset "supertype emission" begin

    @testset "annotated paths subtype the right abstract" begin
        # nested default_concretes — iterate
        # (abs_name, parent_path, concrete_name) triples.
        raw = JSON.parsefile(ABS_JSON)
        for (abs_name, inner) in raw["default_concretes"]
            asym = Symbol(abs_name)
            @test isdefined(IFEdd, asym)
            A = getfield(IFEdd, asym)
            for (_parent_path, concrete_name) in inner
                csym = Symbol(concrete_name)
                @test isdefined(IFEdd, csym)
                C = getfield(IFEdd, csym)
                @test supertype(C{Float64}) === A{Float64}
            end
        end
    end

    @testset "unannotated STRUCTURE nodes keep IMASdd.IDS parent" begin
        raw = JSON.parsefile(ABS_JSON)
        # flatten nested default_concretes to gather all annotated
        # struct names across (abs, parent_path) combinations.
        annotated_structs = Set{String}()
        for (_abs, inner) in raw["default_concretes"]
            for (_p, concrete) in inner
                push!(annotated_structs, concrete)
            end
        end

        unannotated_count = 0
        for fn in readdir(EXTRAS_DIR)
            endswith(fn, ".json") || continue
            schema = JSON.parsefile(joinpath(EXTRAS_DIR, fn))
            for (path, entry) in schema
                entry isa AbstractDict || continue
                dt = get(entry, "data_type", "STRUCTURE")
                dt in ("STRUCTURE", "STRUCT_ARRAY") || continue
                struct_name = IFEdd.path_to_struct_name(path)
                # Skip paths that ARE annotated (those are the 8 entries in lattice)
                struct_name in annotated_structs && continue
                # The struct must exist  and stay at its
                # original IMASdd parent.
                sym = Symbol(struct_name)
                isdefined(IFEdd, sym) || continue
                S = getfield(IFEdd, sym)
                expected_parent = IFEdd.classify_parent(path, entry) * "{Float64}"
                actual_parent_str = string(supertype(S{Float64}))
                if !occursin(expected_parent, actual_parent_str)
                    @error "Unannotated path drifted" path=path struct_name=struct_name expected=expected_parent actual=actual_parent_str
                end
                @test occursin(expected_parent, actual_parent_str)
                unannotated_count += 1
            end
        end
        # An earlier count found 50 STRUCTURE total; shared abstracts
        # adds 5 shared abstracts × 3 hosts = 15 more annotated (50 - 8 - 15
        # = 27 unannotated). Sanity: > 20 visited.
        @test unannotated_count > 20
    end

    @testset "path_to_struct_name round-trip — IFEdd schemas" begin
        for fn in readdir(EXTRAS_DIR)
            endswith(fn, ".json") || continue
            schema = JSON.parsefile(joinpath(EXTRAS_DIR, fn))
            for (path, entry) in schema
                entry isa AbstractDict || continue
                dt = get(entry, "data_type", "STRUCTURE")
                dt in ("STRUCTURE", "STRUCT_ARRAY") || continue
                struct_name = IFEdd.path_to_struct_name(path)
                @test isdefined(IFEdd, Symbol(struct_name))
            end
        end
    end

    @testset "path_to_struct_name table from " begin
        @test IFEdd.path_to_struct_name("summary")                  == "summary"
        @test IFEdd.path_to_struct_name("summary.target")           == "summary__target"
        @test IFEdd.path_to_struct_name("summary.code")             == "summary__code"
        @test IFEdd.path_to_struct_name("build.layer[:]")           == "build__layer"
        @test IFEdd.path_to_struct_name("build.layer[:].outline")   == "build__layer___outline"
        @test IFEdd.path_to_struct_name("driver.beam[:].efficiency") == "driver__beam___efficiency"
        @test IFEdd.path_to_struct_name("summary.ids_properties.plugins.node[:].get_operation[:]") ==
              "summary__ids_properties__plugins__node___get_operation"
        # IMASdd-scale stress
        @test IFEdd.path_to_struct_name("waves.coherent_wave[:].profiles_1d[:].e_field") ==
              "waves__coherent_wave___profiles_1d___e_field"
    end

    @testset "classify_parent dispatches on data_type (F-pre-1)" begin
        @test IFEdd.classify_parent("summary", Dict("data_type" => "STRUCTURE")) == "IMASdd.IDStop"
        @test IFEdd.classify_parent("summary.target", Dict("data_type" => "STRUCTURE")) == "IMASdd.IDS"
        @test IFEdd.classify_parent("build.layer", Dict("data_type" => "STRUCT_ARRAY")) ==
              "IMASdd.IDSvectorStaticElement"
        @test IFEdd.classify_parent("build.layer[:].outline", Dict("data_type" => "STRUCTURE")) ==
              "IMASdd.IDS"
    end

end
