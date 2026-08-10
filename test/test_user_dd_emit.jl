using Test
using IFEdd
using IMASdd
using JSON

# Helpers (Specs A & G from plan §5). Kept inline to avoid a separate
# shared test_helpers.jl file.

"""
    make_synthetic_schema(dir; name="my_thing",
                              supertype="AbstractIFESummary",
                              with_nested=false)

Writes `<dir>/data_structures_extra/<name>.json` matching the user-schema
shape `generate_user_dd` expects. Returns the schema dir path.
"""
function make_synthetic_schema(dir; name="my_thing",
        supertype::Union{String,Nothing}="AbstractIFESummary",
        with_nested=false, with_second::Union{NamedTuple,Nothing}=nothing)
    schema_dir = joinpath(dir, "data_structures_extra")
    mkpath(schema_dir)
    root = Dict{String,Any}(
        "documentation" => "Synthetic test concrete `$name`",
    )
    supertype !== nothing && (root["_supertype"] = supertype)
    body = Dict{String,Any}(
        name => root,
        "$(name).yield" => Dict("data_type" => "FLT_0D",
                                "documentation" => "Fusion yield",
                                "type" => "static", "units" => "MJ"),
    )
    if with_nested
        body["$(name).beam"] = Dict("data_type" => "STRUCTURE",
                                     "documentation" => "Beam params")
        body["$(name).beam.energy"] = Dict("data_type" => "FLT_0D",
                                            "documentation" => "Beam energy",
                                            "type" => "static", "units" => "J")
    end
    if with_second !== nothing
        body[with_second.name] = Dict{String,Any}(
            "_supertype" => with_second.supertype,
            "documentation" => "second concrete",
        )
        body["$(with_second.name).val"] = Dict("data_type" => "FLT_0D",
                                                "documentation" => "v",
                                                "type" => "static", "units" => "-")
    end
    open(joinpath(schema_dir, "$(name).json"), "w") do io
        JSON.print(io, body, 1)
    end
    if with_second !== nothing
        body2 = Dict{String,Any}(
            with_second.name => Dict{String,Any}(
                "_supertype" => with_second.supertype,
                "documentation" => "second concrete",
            ),
            "$(with_second.name).val" => Dict("data_type" => "FLT_0D",
                                               "documentation" => "v",
                                               "type" => "static", "units" => "-"),
        )
        open(joinpath(schema_dir, "$(with_second.name).json"), "w") do io
            JSON.print(io, body2, 1)
        end
        # Remove the leaked entries from the first file so each file owns
        # only its own concrete
        body2_keys = collect(keys(body2))
        for k in body2_keys
            delete!(body, k)
        end
        open(joinpath(schema_dir, "$(name).json"), "w") do io
            JSON.print(io, body, 1)
        end
    end
    return schema_dir
end

"""
    assert_generator_error(reason, f, args...; kwargs...)

Asserts `f(args...; kwargs...)` throws `IFEdd.GeneratorError` whose
`reason` equals the symbol. Pattern from plan §5 Spec G — `@test_throws`
matches type only.
"""
function assert_generator_error(reason::Symbol, f, args...; kwargs...)
    err = try
        f(args...; kwargs...)
        nothing
    catch e
        e
    end
    @test err isa IFEdd.GeneratorError
    if err isa IFEdd.GeneratorError
        @test err.reason === reason
    end
    return err
end

"""
    load_generated(result; mod_name=:GenTest)

Define an anonymous module wrapping the two generated files via `include`
and return it. Avoids cross-test pollution from re-defining the same
top-level module name.
"""
function load_generated(result; mod_name::Symbol=:GenTest)
    src = """
    module $(mod_name)
        using IMASdd
        using IFEdd
        include($(repr(result.idstypes_file)))
        include($(repr(result.dd_file)))
    end
    """
    tmpfile = tempname() * ".jl"
    write(tmpfile, src)
    try
        @eval Main include($tmpfile)
        return getfield(Main, mod_name)
    finally
        rm(tmpfile; force=true)
    end
end

@testset "generate_user_dd: end-to-end" begin

    @testset "happy path: depth-1 user concrete subs summary" begin
        td = mktempdir()
        schema_dir = make_synthetic_schema(td; name="my_summary")
        out_dir = joinpath(td, "out")
        cwd_before = pwd()
        result = IFEdd.generate_user_dd(
            output_dir = out_dir,
            target_module = :GenHappyMod,
            schema_extra_dir = schema_dir,
            slot_bindings = Dict(:summary => :my_summary),
        )
        @test isfile(result.idstypes_file)
        @test isfile(result.dd_file)
        @test isfile(result.manifest_file)
        # cwd stable
        @test pwd() == cwd_before

        # Manifest assertions
        @test result.manifest["target_module"] == "GenHappyMod"
        @test result.manifest["slot_bindings"]["summary"]["concrete"] == "my_summary"
        @test result.manifest["slot_bindings"]["summary"]["source"] == "user"
        @test result.manifest["slot_bindings"]["build"]["source"] == "ifedd-default"

        # Source content invariants
        ids_content = read(result.idstypes_file, String)
        dd_content = read(result.dd_file, String)
        @test occursin("mutable struct my_summary{T} <: IFEdd.AbstractIFESummary{T}",
                       ids_content)
        @test occursin("mutable struct dd{T} <: IFEdd.AbstractIFEDD{T}", dd_content)
        # Companion struct uses the canonical prefix
        @test occursin("FilledFields____my_summary", ids_content)
        # Container has all 11 slots
        for slot in ("balance_of_plant", "blanket", "build", "core_profiles",
                     "core_sources", "costing", "driver", "neutronics",
                     "pellets", "requirements", "summary")
            @test occursin("var\"$(slot)\"::", dd_content)
        end
        # Bound slot has user concrete (no prefix because in-user-module)
        @test occursin("var\"summary\"::my_summary{T}", dd_content)
        # IFEdd default slots use IFEdd.X{T}
        @test occursin("var\"build\"::IFEdd.build{T}", dd_content)
        @test occursin("var\"driver\"::IFEdd.driver{T}", dd_content)
        # IMASdd-only slots use IMASdd.X{T}
        @test occursin("var\"pellets\"::IMASdd.pellets{T}", dd_content)

        # No leftover GenerateDD `dd` struct in idstypes (we strip it)
        @test !occursin("mutable struct dd{T}", ids_content)

        # Load the module and exercise
        m = load_generated(result; mod_name=:GenHappyMod)
        d = m.dd()
        @test d isa IMASdd.DD{Float64}
        @test d.summary isa m.my_summary{Float64}
        @test d.summary isa IFEdd.AbstractIFESummary{Float64}
        @test d.summary isa IMASdd.IDStop{Float64}
        @test d.build isa IFEdd.build{Float64}
        @test d.driver isa IFEdd.driver{Float64}
        @test d.pellets isa IMASdd.pellets{Float64}

        # _name slot fix (so add_filled works)
        @test getfield(d.summary, :_name) === :summary
        @test getfield(d.build,   :_name) === :build

        # Round-trip a field write/read (exercises add_filled)
        d.summary.yield = 42.0
        @test d.summary.yield == 42.0
        @test getfield(d, :_filled).summary == true

        # _parent linkage
        @test getfield(d.summary, :_parent).value === d
        @test getfield(d.build,   :_parent).value === d
    end

    @testset "manifest canonical determinism" begin
        td = mktempdir()
        schema_dir = make_synthetic_schema(td; name="ms2")
        result1 = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out1"),
            target_module = :GenManifestA,
            schema_extra_dir = schema_dir,
            slot_bindings = Dict(:summary => :ms2),
        )
        result2 = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out2"),
            target_module = :GenManifestA,
            schema_extra_dir = schema_dir,
            slot_bindings = Dict(:summary => :ms2),
        )
        # Read raw bytes from both manifests, compare `inputs` and
        # `slot_bindings` blocks (the order-independent invariants).
        m1 = JSON.parsefile(result1.manifest_file)
        m2 = JSON.parsefile(result2.manifest_file)
        @test m1["inputs"] == m2["inputs"]
        @test m1["slot_bindings"] == m2["slot_bindings"]
        @test m1["outputs"] == m2["outputs"]

        # Source files are byte-identical
        @test read(result1.idstypes_file) == read(result2.idstypes_file)
        @test read(result1.dd_file) == read(result2.dd_file)
    end

    @testset "JSON-implied binding (no slot_bindings kwarg)" begin
        td = mktempdir()
        # Single user concrete declaring `_supertype: AbstractIFEDriver`
        schema_dir = make_synthetic_schema(td; name="my_driver",
                                            supertype="AbstractIFEDriver")
        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :GenJSONImplied,
            schema_extra_dir = schema_dir,
            # NO slot_bindings — JSON-implied binding picks up `my_driver`
        )
        @test result.manifest["slot_bindings"]["driver"]["concrete"] == "my_driver"
        @test result.manifest["slot_bindings"]["driver"]["source"] == "user"
        @test result.manifest["slot_bindings"]["summary"]["source"] == "ifedd-default"
    end

    @testset "GeneratorError: schema_dir_missing" begin
        assert_generator_error(:schema_dir_missing, IFEdd.generate_user_dd;
            output_dir = mktempdir(),
            target_module = :GenSchemaMissing,
            schema_extra_dir = joinpath(tempname(), "nope"))
    end

    @testset "GeneratorError: bad_supertype" begin
        td = mktempdir()
        schema_dir = make_synthetic_schema(td; name="x",
                                            supertype="AbstractDoesNotExist")
        assert_generator_error(:bad_supertype, IFEdd.generate_user_dd;
            output_dir = joinpath(td, "out"),
            target_module = :GenBadSuper,
            schema_extra_dir = schema_dir)
    end

    @testset "GeneratorError: supertype_mismatch" begin
        td = mktempdir()
        # User declares AbstractIFEBuild but kwarg points it at :summary slot
        schema_dir = make_synthetic_schema(td; name="mymis",
                                            supertype="AbstractIFEBuild")
        assert_generator_error(:supertype_mismatch, IFEdd.generate_user_dd;
            output_dir = joinpath(td, "out"),
            target_module = :GenSuperMismatch,
            schema_extra_dir = schema_dir,
            slot_bindings = Dict(:summary => :mymis))
    end

    @testset "GeneratorError: concrete_not_in_schemas" begin
        td = mktempdir()
        schema_dir = make_synthetic_schema(td; name="exists")
        assert_generator_error(:concrete_not_in_schemas, IFEdd.generate_user_dd;
            output_dir = joinpath(td, "out"),
            target_module = :GenMissingConcrete,
            schema_extra_dir = schema_dir,
            slot_bindings = Dict(:summary => :does_not_exist))
    end

    @testset "GeneratorError: ambiguous_binding" begin
        td = mktempdir()
        # Two user schemas both declare `_supertype: AbstractIFESummary`
        schema_dir = make_synthetic_schema(td; name="sumA",
            supertype="AbstractIFESummary",
            with_second=(name="sumB", supertype="AbstractIFESummary"))
        assert_generator_error(:ambiguous_binding, IFEdd.generate_user_dd;
            output_dir = joinpath(td, "out"),
            target_module = :GenAmbiguous,
            schema_extra_dir = schema_dir)
    end

    @testset "GeneratorError: user_name_shadows_ifedd_default" begin
        td = mktempdir()
        # User names their concrete `summary` — collides with IFEdd's default
        schema_dir = make_synthetic_schema(td; name="summary",
                                            supertype="AbstractIFESummary")
        assert_generator_error(:user_name_shadows_ifedd_default,
            IFEdd.generate_user_dd;
            output_dir = joinpath(td, "out"),
            target_module = :GenShadow,
            schema_extra_dir = schema_dir)
    end

    @testset "GeneratorError: subdir_in_schema_dir" begin
        td = mktempdir()
        sd = joinpath(td, "data_structures_extra")
        mkpath(sd)
        mkdir(joinpath(sd, "uninvited_dir"))
        assert_generator_error(:subdir_in_schema_dir, IFEdd.generate_user_dd;
            output_dir = joinpath(td, "out"),
            target_module = :GenSubdir,
            schema_extra_dir = sd)
    end

    @testset "GeneratorError: malformed_json" begin
        td = mktempdir()
        sd = joinpath(td, "data_structures_extra")
        mkpath(sd)
        write(joinpath(sd, "broken.json"), "{this is not json")
        assert_generator_error(:malformed_json, IFEdd.generate_user_dd;
            output_dir = joinpath(td, "out"),
            target_module = :GenMalformed,
            schema_extra_dir = sd)
    end

    @testset "GeneratorError: ifedd_not_locatable (forced)" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="anyname")
        IFEdd._FORCE_PKGDIR_NIL[] = true
        try
            assert_generator_error(:ifedd_not_locatable, IFEdd.generate_user_dd;
                output_dir = joinpath(td, "out"),
                target_module = :GenNoIfedd,
                schema_extra_dir = sd)
        finally
            IFEdd._FORCE_PKGDIR_NIL[] = false
        end
    end

    @testset "user schema declares nested _supertype" begin
        td = mktempdir()
        schema_dir = joinpath(td, "data_structures_extra")
        mkpath(schema_dir)
        # my_summary with a nested target carrying _supertype
        body = Dict{String,Any}(
            "p15_nested" => Dict("_supertype" => "AbstractIFESummary",
                                  "documentation" => "wrapper"),
            "p15_nested.yield" => Dict("data_type" => "FLT_0D",
                                        "documentation" => "y",
                                        "type" => "static", "units" => "MJ"),
            "p15_nested.target" => Dict("_supertype" => "AbstractIFESummaryTarget",
                                         "data_type" => "STRUCTURE",
                                         "documentation" => "nested"),
            "p15_nested.target.gain" => Dict("data_type" => "FLT_0D",
                                              "documentation" => "g",
                                              "type" => "static", "units" => "-"),
        )
        open(joinpath(schema_dir, "p15_nested.json"), "w") do io
            JSON.print(io, body, 1)
        end
        out_dir = joinpath(td, "out")
        result = IFEdd.generate_user_dd(
            output_dir = out_dir,
            target_module = :GenNested,
            schema_extra_dir = schema_dir,
            slot_bindings = Dict(:summary => :p15_nested),
        )

        # Source-level: both top-level AND nested struct subtype IFEdd's abstracts (qualified)
        ids_content = read(result.idstypes_file, String)
        @test occursin("mutable struct p15_nested{T} <: IFEdd.AbstractIFESummary{T}",
                       ids_content)
        @test occursin("mutable struct p15_nested__target{T} <: IFEdd.AbstractIFESummaryTarget{T}",
                       ids_content)

        # Load and assert dispatch via abstracts
        m = load_generated(result; mod_name=:GenNestedMod)
        @test m.p15_nested{Float64}        <: IFEdd.AbstractIFESummary{Float64}
        @test m.p15_nested__target{Float64} <: IFEdd.AbstractIFESummaryTarget{Float64}
        d = m.dd()
        @test d.summary isa m.p15_nested{Float64}
        @test d.summary.target isa m.p15_nested__target{Float64}

        # Parallel-typing-not-substitution: IFEdd's own dd is untouched.
        # The IFEdd-baked summary still embeds IFEdd.summary__target, NOT
        # the user's p15_nested__target.
        ifedd_d = IFEdd.dd()
        @test typeof(ifedd_d.summary.target) === IFEdd.summary__target{Float64}
        @test typeof(ifedd_d.summary.target) !== Main.GenNestedMod.p15_nested__target{Float64}
    end

    @testset ":unknown_abstract — bad abstract on a NESTED user marker" begin
        # Top-level marker references a VALID lattice abstract (so the
        # top-level kwarg path passes :bad_supertype); the failure must
        # come from the nested walker on a depth-2 path.
        td = mktempdir()
        schema_dir = joinpath(td, "data_structures_extra")
        mkpath(schema_dir)
        body = Dict{String,Any}(
            "p15_unkabs" => Dict("_supertype" => "AbstractIFESummary",
                                  "documentation" => "OK at top"),
            "p15_unkabs.x" => Dict("_supertype" => "AbstractIFENotAThing",
                                    "data_type" => "STRUCTURE",
                                    "documentation" => "bad at depth-1"),
            "p15_unkabs.x.y" => Dict("data_type" => "FLT_0D",
                                      "documentation" => "leaf",
                                      "type" => "static", "units" => "-"),
        )
        open(joinpath(schema_dir, "p15_unkabs.json"), "w") do io
            JSON.print(io, body, 1)
        end
        assert_generator_error(:unknown_abstract, IFEdd.generate_user_dd;
            output_dir = joinpath(td, "out"),
            target_module = :GenUnknownAbs,
            schema_extra_dir = schema_dir,
            slot_bindings = Dict(:summary => :p15_unkabs))
    end

    @testset "version-skew @warn fires when abstracts hash changes" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="my_vs")
        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :GenVS,
            schema_extra_dir = sd,
            slot_bindings = Dict(:summary => :my_vs),
        )
        # Patch the baked hash to a bogus value
        original = read(result.dd_file, String)
        patched = replace(original,
            r"_IFEDD_ABSTRACTS_HASH_AT_BAKE\s*=\s*\"[0-9a-f]+\"" =>
            "_IFEDD_ABSTRACTS_HASH_AT_BAKE = \"deadbeef\"")
        @test patched != original   # confirm regex matched
        write(result.dd_file, patched)

        # Loading should produce a @warn whose message names the hash drift.
        src = """
        module GenVSTest
            using IMASdd
            using IFEdd
            include($(repr(result.idstypes_file)))
            include($(repr(result.dd_file)))
        end
        """
        tmp = tempname() * ".jl"
        write(tmp, src)
        try
            @test_logs (:warn, r"sha256") match_mode=:any begin
                @eval Main include($tmp)
            end
        finally
            rm(tmp; force=true)
        end
    end

    @testset "pidlock serializes concurrent generation" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="ms_conc")
        out_dir = joinpath(td, "out")
        order = Int[]
        olock = ReentrantLock()
        t1 = Threads.@spawn begin
            IFEdd.generate_user_dd(
                output_dir = out_dir,
                target_module = :GenConc1,
                schema_extra_dir = sd,
                slot_bindings = Dict(:summary => :ms_conc),
            )
            lock(olock) do; push!(order, 1) end
        end
        sleep(0.05)
        t2 = Threads.@spawn begin
            IFEdd.generate_user_dd(
                output_dir = out_dir,
                target_module = :GenConc2,
                schema_extra_dir = sd,
                slot_bindings = Dict(:summary => :ms_conc),
            )
            lock(olock) do; push!(order, 2) end
        end
        wait(t1); wait(t2)
        @test sort(order) == [1, 2]
        # Both target files should exist
        @test isfile(joinpath(out_dir, "GenConc1_dd.jl"))
        @test isfile(joinpath(out_dir, "GenConc2_dd.jl"))
    end

end
