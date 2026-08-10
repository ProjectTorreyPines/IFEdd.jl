using Test
using IFEdd
using IMASdd
using JSON

# Freshness regression + on-disk template + smoke load for the
# `test/fixtures/MyIFEProject/` synthetic user package.
#
# The fixture is the public face of the `IFEdd.generate_user_dd` API:
# its three GEN files (committed) must match what the live generator
# emits today, and the fixture must construct + dispatch through the
# AbstractIFE* lattice end-to-end. `test_user_dd_emit.jl`
# carries the unit-level correctness; this file is the **regression
# layer**: any PR that changes the generator or `abstracts.json` must
# also `julia --project test/fixtures/regen_fixture.jl` and commit
# the diff.

const FIXTURE_ROOT = joinpath(@__DIR__, "fixtures", "MyIFEProject")
const FIXTURE_SCHEMA_DIR = joinpath(FIXTURE_ROOT, "data_dictionary",
                                    "data_structures_extra")
const FIXTURE_SRC = joinpath(FIXTURE_ROOT, "src")

@testset "MyIFEProject fixture" begin

    @testset "all fixture files are committed" begin
        for f in ("Project.toml",
                  "data_dictionary/data_structures_extra/my_summary.json",
                  "deps/build.jl",
                  "src/MyIFEProject.jl",
                  "src/MyIFEProject_idstypes.jl",
                  "src/MyIFEProject_dd.jl",
                  "src/MyIFEProject_dd_manifest.json",
                  "test/runtests.jl",
                  "README.md")
            @test isfile(joinpath(FIXTURE_ROOT, f))
        end
    end

    @testset "freshness — regenerated output matches committed" begin
        td = mktempdir()
        result = IFEdd.generate_user_dd(
            output_dir       = td,
            target_module    = :MyIFEProject,
            schema_extra_dir = FIXTURE_SCHEMA_DIR,
            slot_bindings    = Dict(:summary => :my_summary),
        )

        # Byte-compare the two .jl files
        for f in ("MyIFEProject_idstypes.jl", "MyIFEProject_dd.jl")
            committed = read(joinpath(FIXTURE_SRC, f), String)
            fresh = read(joinpath(td, f), String)
            if committed != fresh
                @error """
                Fixture freshness FAILED for $(f).

                The committed copy in
                    $(joinpath(FIXTURE_SRC, f))
                differs from the live `IFEdd.generate_user_dd` output.

                To fix:
                    julia --project test/fixtures/regen_fixture.jl
                    git add test/fixtures/MyIFEProject/src/
                    git commit
                """
            end
            @test committed == fresh
        end

        # Manifest: compare structure modulo non-deterministic fields.
        # (Generator does not currently embed `generated_at`; if that
        # changes, filter it here.)
        committed_manifest = JSON.parsefile(joinpath(FIXTURE_SRC,
                                              "MyIFEProject_dd_manifest.json"))
        fresh_manifest = JSON.parsefile(joinpath(td,
                                                  "MyIFEProject_dd_manifest.json"))
        @test committed_manifest == fresh_manifest
    end

    @testset "fixture loads + exercises end-to-end" begin
        # Load via include into a fresh anonymous module. Mirrors what
        # `Pkg.develop` + `using MyIFEProject` does in real downstream use
        # but avoids touching the parent test process's environment.
        mod_name = :MyIFEProjectInTestSession
        # The fixture's MyIFEProject.jl `include`s relative paths, so we
        # include it from its own directory.
        src = """
        module $(mod_name)
            using IMASdd
            using IFEdd
            include($(repr(joinpath(FIXTURE_SRC, "MyIFEProject_idstypes.jl"))))
            include($(repr(joinpath(FIXTURE_SRC, "MyIFEProject_dd.jl"))))
        end
        """
        tmp = tempname() * ".jl"
        write(tmp, src)
        try
            @eval Main include($tmp)
            m = getfield(Main, mod_name)

            # Shape
            @test isdefined(m, :dd)
            @test isdefined(m, :my_summary)
            @test isdefined(m, :my_summary__beam)

            d = m.dd()
            @test typeof(d) === m.dd{Float64}
            @test d isa IFEdd.AbstractIFEDD{Float64}
            @test d isa IMASdd.DD{Float64}
            @test d.summary isa m.my_summary{Float64}
            @test d.summary isa IFEdd.AbstractIFESummary{Float64}
            # Robust type-identity assertion (plan Critique 1 G8)
            @test Base.unwrap_unionall(typeof(d.summary)) <: IFEdd.AbstractIFESummary

            # Default slots intact
            @test d.build isa IFEdd.build{Float64}
            @test d.driver isa IFEdd.driver{Float64}
            @test d.pellets isa IMASdd.pellets{Float64}
            @test d.balance_of_plant isa IMASdd.balance_of_plant{Float64}

            # _name slot fix
            @test getfield(d.summary, :_name) === :summary
            @test getfield(d.build,   :_name) === :build

            # depth-1 round-trip exercises add_filled across the dd
            d.summary.yield = 7.5
            @test d.summary.yield == 7.5
            @test getfield(d, :_filled).summary == true

            # depth-2 round-trip exercises nested struct emission
            @test d.summary.beam isa m.my_summary__beam{Float64}
            d.summary.beam.energy = 1.5e6
            @test d.summary.beam.energy == 1.5e6
        finally
            rm(tmp; force=true)
        end
    end

end
