using Test
using IFEdd
using IMASdd
using JSON

# Byte-equal freshness gate + end-to-end load smoke for the sub-IDS fixture.
# Mirrors test_user_dd_fixture.jl; covers the
# substitution-graph + 4-pass regex rewriter against the in-tree
# `test/fixtures/MyIFEProject_subids/` artifacts.

const SUBIDS_FIXTURE_ROOT = joinpath(@__DIR__, "fixtures", "MyIFEProject_subids")
const P2_FIXTURE_SCHEMA_DIR = joinpath(SUBIDS_FIXTURE_ROOT, "data_dictionary",
                                      "data_structures_extra")
const SUBIDS_FIXTURE_SRC = joinpath(SUBIDS_FIXTURE_ROOT, "src")

@testset "MyIFEProject_subids fixture" begin

    @testset "all fixture files are committed" begin
        for f in ("Project.toml",
                  "data_dictionary/data_structures_extra/my_layer.json",
                  "data_dictionary/data_structures_extra/my_efficiency.json",
                  "src/MyIFEProject_subids.jl",
                  "src/MyIFEProject_subids_idstypes.jl",
                  "src/MyIFEProject_subids_dd.jl",
                  "src/MyIFEProject_subids_dd_manifest.json",
                  "README.md")
            @test isfile(joinpath(SUBIDS_FIXTURE_ROOT, f))
        end
    end

    @testset "freshness — regenerated output matches committed" begin
        td = mktempdir()
        result = IFEdd.generate_user_dd(
            output_dir       = td,
            target_module    = :MyIFEProject_subids,
            schema_extra_dir = P2_FIXTURE_SCHEMA_DIR,
            slot_bindings    = Dict(
                :AbstractIFEBuildLayer           => :my_layer,
                :AbstractIFEDriverBeamEfficiency => :my_efficiency,
            ),
        )

        for f in ("MyIFEProject_subids_idstypes.jl",
                  "MyIFEProject_subids_dd.jl")
            committed = read(joinpath(SUBIDS_FIXTURE_SRC, f), String)
            fresh = read(joinpath(td, f), String)
            if committed != fresh
                @error """
                sub-IDS fixture freshness FAILED for $(f).

                The committed copy in
                    $(joinpath(SUBIDS_FIXTURE_SRC, f))
                differs from the live `IFEdd.generate_user_dd` output.

                To fix:
                    julia --project test/fixtures/regenerate_subids_fixture.jl
                    git add test/fixtures/MyIFEProject_subids/src/
                    git commit
                """
            end
            @test committed == fresh
        end

        # Manifest: value-equal modulo non-deterministic fields (currently none).
        committed_manifest = JSON.parsefile(joinpath(SUBIDS_FIXTURE_SRC,
                                              "MyIFEProject_subids_dd_manifest.json"))
        fresh_manifest = JSON.parsefile(joinpath(td,
                                              "MyIFEProject_subids_dd_manifest.json"))
        @test committed_manifest == fresh_manifest
    end

    @testset "fixture loads + exercises sub-IDS substitution end-to-end" begin
        mod_name = :MyIFEProject_subids_InTest
        src = """
        module $(mod_name)
            using IMASdd, IFEdd
            include($(repr(joinpath(SUBIDS_FIXTURE_SRC, "MyIFEProject_subids_idstypes.jl"))))
            include($(repr(joinpath(SUBIDS_FIXTURE_SRC, "MyIFEProject_subids_dd.jl"))))
        end
        """
        tmp = tempname() * ".jl"
        write(tmp, src)
        try
            @eval Main include($tmp)
            m = getfield(Main, mod_name)

            # Shape
            @test isdefined(m, :dd)
            @test isdefined(m, :my_layer)
            @test isdefined(m, :my_efficiency)
            @test isdefined(m, :build)       # customized parent emitted locally
            @test isdefined(m, :driver)
            @test isdefined(m, :driver__beam)

            # Customized parent is distinct from IFEdd's
            @test m.build !== IFEdd.build
            @test m.driver !== IFEdd.driver

            # Substituted field types
            @test fieldtype(m.build{Float64}, :layer) ===
                  IMASdd.IDSvector{m.my_layer{Float64}}
            @test fieldtype(m.driver__beam{Float64}, :efficiency) ===
                  m.my_efficiency{Float64}

            # Construct + push round-trip (no manual _name fixup)
            d = m.dd()
            @test typeof(d.build) === m.build{Float64}
            @test typeof(d.driver) === m.driver{Float64}
            layer = m.my_layer{Float64}()
            layer.name = "first_wall"
            layer.thickness = 0.05
            layer.cost_rate = 1200.0
            push!(d.build.layer, layer)
            @test d.build.layer[1] isa m.my_layer{Float64}
            @test d.build.layer[1] isa IFEdd.AbstractIFEBuildLayer{Float64}
            @test d.build.layer[1].cost_rate == 1200.0

            # driver.beam[1].efficiency is the user concrete (after a push)
            push!(d.driver.beam, m.driver__beam{Float64}())
            @test d.driver.beam[1].efficiency isa m.my_efficiency{Float64}
            @test d.driver.beam[1].efficiency isa IFEdd.AbstractIFEDriverBeamEfficiency{Float64}

            # Parallel-typing preservation: IFEdd.dd() untouched
            ifedd_d = IFEdd.dd()
            @test fieldtype(IFEdd.build{Float64}, :layer) ===
                  IMASdd.IDSvector{IFEdd.build__layer{Float64}}
            @test typeof(ifedd_d.build) === IFEdd.build{Float64}
        finally
            rm(tmp; force=true)
        end
    end

end
