using Test
using IFEdd
using IMASdd
using JSON

# End-to-end emission tests. Exercises:
# - pipeline wiring (substitution_graph → expand_workdir → regex pass)
# - field-type + ctor-call substitution at all depths
# - parent-IDS regen with supertype recovery
# - duplicate element-type struct strip
# - _name rewrite (Pass iii) + IDSvector._name fix (Pass iv)
# - runtime dispatch + push + field round-trip
# - parallel-typing preservation (IFEdd.dd() unchanged)

"""
    p2_user_layer_schema(td, name; supertype="AbstractIFEBuildLayer") -> schema_dir

Write a synthetic STRUCT_ARRAY-element user schema mirroring the
 shape (`<name>[:].field` form). Returns the dir.
"""
function p2_user_layer_schema(td, name="my_layer";
                              supertype="AbstractIFEBuildLayer")
    schema_dir = joinpath(td, "data_structures_extra")
    mkpath(schema_dir)
    body = Dict{String,Any}(
        name => Dict("_supertype" => supertype,
                     "data_type" => "STRUCT_ARRAY",
                     "documentation" => "Synthetic"),
        "$(name)[:].name"      => Dict("data_type" => "STR_0D",
                                        "documentation" => "name",
                                        "type" => "static"),
        "$(name)[:].cost"      => Dict("data_type" => "FLT_0D",
                                        "documentation" => "cost",
                                        "type" => "static",
                                        "units" => "USD"),
        "$(name)[:].thickness" => Dict("data_type" => "FLT_0D",
                                        "documentation" => "t",
                                        "type" => "static",
                                        "units" => "m"),
    )
    open(joinpath(schema_dir, "$(name).json"), "w") do io
        JSON.print(io, body, 1)
    end
    return schema_dir
end

"""
    p2_user_direct_schema(td, name; supertype) -> schema_dir

Direct STRUCTURE (IDS) embed shape — `<name>.field`, no `[:]`.
"""
function p2_user_direct_schema(td, name="my_efficiency";
                                supertype="AbstractIFEDriverBeamEfficiency")
    schema_dir = joinpath(td, "data_structures_extra")
    mkpath(schema_dir)
    body = Dict{String,Any}(
        name => Dict("_supertype" => supertype,
                     "data_type" => "STRUCTURE",
                     "documentation" => "Synthetic"),
        "$(name).conversion"        => Dict("data_type" => "FLT_0D",
                                             "documentation" => "η_conv",
                                             "type" => "static"),
        "$(name).coupling"          => Dict("data_type" => "FLT_0D",
                                             "documentation" => "η_coup",
                                             "type" => "static"),
        "$(name).cooling_correction" => Dict("data_type" => "FLT_0D",
                                              "documentation" => "NEW field",
                                              "type" => "static"),
    )
    open(joinpath(schema_dir, "$(name).json"), "w") do io
        JSON.print(io, body, 1)
    end
    return schema_dir
end

"""
    load_p2_generated(result, mod_name) -> Module

Load generated user dd into an anonymous Main sub-module.
Returns the module.
"""
function load_p2_generated(result, mod_name::Symbol)
    src = """
    module $(mod_name)
        using IMASdd, IFEdd
        include($(repr(result.idstypes_file)))
        include($(repr(result.dd_file)))
    end
    """
    tmp = tempname() * ".jl"
    write(tmp, src)
    try
        @eval Main include($tmp)
        return getfield(Main, mod_name)
    finally
        rm(tmp; force=true)
    end
end

@testset "emission — end-to-end substitution" begin

    @testset "IDSvectorStaticElement substitution: build.layer" begin
        td = mktempdir()
        sd = p2_user_layer_schema(td, "p2e_layer")
        out_dir = joinpath(td, "out")
        result = IFEdd.generate_user_dd(
            output_dir = out_dir,
            target_module = :P2EmitL,
            schema_extra_dir = sd,
            slot_bindings = Dict(:AbstractIFEBuildLayer => :p2e_layer),
        )

        # Source-level invariants
        ids_content = read(result.idstypes_file, String)
        @test occursin("mutable struct p2e_layer{T} <: IFEdd.AbstractIFEBuildLayer{T}",
                       ids_content)
        @test occursin("mutable struct build{T} <: IFEdd.AbstractIFEBuild{T}",
                       ids_content)
        @test occursin("var\"layer\"::IMASdd.IDSvector{p2e_layer{T}}", ids_content)
        @test !occursin("var\"layer\"::IMASdd.IDSvector{build__layer{T}}", ids_content)
        # Pass iii: my_layer ctor uses Symbol("layer"), not Symbol("p2e_layer")
        @test occursin("Symbol(\"layer\")", ids_content)
        # Pass iv: parent build ctor injects _name fix
        @test occursin("setfield!(ids.layer, :_name, :layer)", ids_content)

        dd_content = read(result.dd_file, String)
        # dd container's build slot uses bare `build{T}` (local custom)
        @test occursin("var\"build\"::build{T}", dd_content)
        @test !occursin("var\"build\"::IFEdd.build{T}", dd_content)

        # Load and verify runtime
        m = load_p2_generated(result, :P2EmitLMod)
        d = m.dd()
        @test typeof(d.build) === m.build{Float64}
        @test typeof(d.build) !== IFEdd.build{Float64}
        @test fieldtype(m.build{Float64}, :layer) ===
              IMASdd.IDSvector{m.p2e_layer{Float64}}

        # Push round-trip (no manual setfield needed — Pass iii+iv handle _name)
        layer1 = m.p2e_layer{Float64}()
        layer1.cost = 1500.0
        layer1.thickness = 0.05
        push!(d.build.layer, layer1)
        @test length(d.build.layer) == 1
        @test d.build.layer[1] isa m.p2e_layer{Float64}
        @test d.build.layer[1] isa IFEdd.AbstractIFEBuildLayer{Float64}
        @test d.build.layer[1].cost == 1500.0
    end

    @testset "IDS substitution: driver.beam.efficiency" begin
        td = mktempdir()
        sd = p2_user_direct_schema(td, "p2e_eff")
        out_dir = joinpath(td, "out")
        result = IFEdd.generate_user_dd(
            output_dir = out_dir,
            target_module = :P2EmitE,
            schema_extra_dir = sd,
            slot_bindings = Dict(:AbstractIFEDriverBeamEfficiency => :p2e_eff),
        )

        ids_content = read(result.idstypes_file, String)
        @test occursin("mutable struct p2e_eff{T} <: IFEdd.AbstractIFEDriverBeamEfficiency{T}",
                       ids_content)
        @test occursin("var\"efficiency\"::p2e_eff{T}", ids_content)
        @test !occursin("var\"efficiency\"::driver__beam___efficiency{T}", ids_content)
        # Pass iii: ctor uses :efficiency
        @test occursin("Symbol(\"efficiency\")", ids_content)

        m = load_p2_generated(result, :P2EmitEMod)
        d = m.dd()
        # driver.beam now uses customized driver__beam (containing p2e_eff)
        # NOTE: driver__beam itself was regenerated as parent IDS
        beam_type = fieldtype(typeof(d.driver), :beam)
        @test beam_type <: IMASdd.IDSvector
        # The element type's efficiency field should be p2e_eff
        # (need to push a beam first to inspect)
        push!(d.driver.beam, eltype(beam_type)())
        @test d.driver.beam[1].efficiency isa m.p2e_eff{Float64}
        @test d.driver.beam[1].efficiency isa IFEdd.AbstractIFEDriverBeamEfficiency{Float64}
    end

    @testset "parallel-typing preservation: IFEdd.dd() unchanged" begin
        # After generation runs, IFEdd's own dd() must still
        # construct with its DEFAULT concretes — substitution is per-bake,
        # not global.
        td = mktempdir()
        sd = p2_user_layer_schema(td, "p2e_layer_parallel")
        IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :P2EmitParallel,
            schema_extra_dir = sd,
            slot_bindings = Dict(:AbstractIFEBuildLayer => :p2e_layer_parallel),
        )
        # IFEdd's container untouched
        ifedd_d = IFEdd.dd()
        @test fieldtype(IFEdd.build{Float64}, :layer) ===
              IMASdd.IDSvector{IFEdd.build__layer{Float64}}
        @test typeof(ifedd_d.build) === IFEdd.build{Float64}
    end

    @testset "backward compatibility — top-level-only invocation" begin
        # A user passing only top-level keys gets ZERO substitution wiring;
        # the dd file is byte-identical to the unsubstituted output.
        td = mktempdir()
        sd = joinpath(td, "data_structures_extra")
        mkpath(sd)
        body = Dict{String,Any}(
            "p2bc_summary" => Dict("_supertype" => "AbstractIFESummary",
                                    "documentation" => "P1 form"),
            "p2bc_summary.yield" => Dict("data_type" => "FLT_0D",
                                          "documentation" => "y",
                                          "type" => "static", "units" => "MJ"),
        )
        open(joinpath(sd, "p2bc_summary.json"), "w") do io
            JSON.print(io, body, 1)
        end
        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :P2BCMod,
            schema_extra_dir = sd,
            slot_bindings = Dict(:summary => :p2bc_summary),   # top-level slot form
        )
        dd_content = read(result.dd_file, String)
        # build slot stays IFEdd-qualified (no substitution)
        @test occursin("var\"build\"::IFEdd.build{T}", dd_content)
        @test occursin("var\"driver\"::IFEdd.driver{T}", dd_content)
        # summary is the user concrete
        @test occursin("var\"summary\"::p2bc_summary{T}", dd_content)
    end

    @testset "shared abstract substitution via the nested-dict form (build.code only)" begin
        # Bind AbstractIDSCode at a SINGLE host path via nested-dict form.
        # The other 2 hosts (summary.code, driver.code) stay on
        # IFEdd defaults. Verify emitted parent (build) has its code
        # field type substituted while summary / driver are untouched.
        td = mktempdir()
        schema_dir = joinpath(td, "data_structures_extra")
        mkpath(schema_dir)
        body = Dict{String,Any}(
            "p25_code" => Dict("_supertype" => "AbstractIDSCode",
                                "data_type" => "STRUCTURE",
                                "documentation" => "Custom code substructure"),
            "p25_code.commit" => Dict("data_type" => "STR_0D",
                                       "documentation" => "Git commit",
                                       "type" => "constant"),
            "p25_code.name" => Dict("data_type" => "STR_0D",
                                     "documentation" => "Software name",
                                     "type" => "constant"),
            "p25_code.audit_id" => Dict("data_type" => "STR_0D",
                                         "documentation" => "NEW field — audit reference",
                                         "type" => "constant"),
        )
        open(joinpath(schema_dir, "p25_code.json"), "w") do io
            JSON.print(io, body, 1)
        end
        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :P25Emit,
            schema_extra_dir = schema_dir,
            # F2: shared abstract bound at exactly one host (build)
            slot_bindings = Dict(:AbstractIDSCode => Dict(:build => :p25_code)),
        )

        ids_content = read(result.idstypes_file, String)
        @test occursin("mutable struct p25_code{T} <: IFEdd.AbstractIDSCode{T}",
                       ids_content)
        # build's code field type is substituted
        @test occursin("var\"code\"::p25_code{T}", ids_content)
        @test !occursin("var\"code\"::build__code{T}", ids_content)

        # Load and verify dispatch + parallel-typing
        m = load_p2_generated(result, :P25EmitMod)
        d = m.dd()
        @test typeof(d.build) === m.build{Float64}
        @test fieldtype(m.build{Float64}, :code) === m.p25_code{Float64}
        @test m.p25_code{Float64} <: IFEdd.AbstractIDSCode{Float64}
        # IFEdd's own defaults still subtype AbstractIDSCode
        @test IFEdd.build__code{Float64} <: IFEdd.AbstractIDSCode{Float64}
        @test IFEdd.summary__code{Float64} <: IFEdd.AbstractIDSCode{Float64}
        # IFEdd.dd() unchanged
        @test fieldtype(IFEdd.build{Float64}, :code) === IFEdd.build__code{Float64}
    end

    @testset "auto-recursive substitution at nested user marker" begin
        # User schemas:
        #   p4e_layer.json  — STRUCT_ARRAY element with NESTED `_supertype`
        #                     marker on `p4e_layer[:].outline` declaring
        #                     `AbstractIFEBuildLayerOutline`.
        #   p4e_outline.json — STRUCTURE concrete satisfying that abstract.
        # User binds BOTH abstracts. Without auto-recursion, p4e_layer's `outline`
        # field stays the nested default `p4e_layer___outline{T}`. With
        # auto-recursion, it auto-substitutes to `p4e_outline{T}`.
        td = mktempdir()
        sd = joinpath(td, "data_structures_extra")
        mkpath(sd)
        # Outline concrete (separate file)
        outline_body = Dict{String,Any}(
            "p4e_outline" => Dict("_supertype" => "AbstractIFEBuildLayerOutline",
                                   "data_type" => "STRUCTURE",
                                   "documentation" => "user outline"),
            "p4e_outline.r" => Dict("data_type" => "FLT_1D",
                                     "documentation" => "radial coord",
                                     "type" => "static"),
            "p4e_outline.z" => Dict("data_type" => "FLT_1D",
                                     "documentation" => "axial coord",
                                     "type" => "static"),
        )
        open(joinpath(sd, "p4e_outline.json"), "w") do io
            JSON.print(io, outline_body, 1)
        end
        # Layer with nested outline marker
        layer_body = Dict{String,Any}(
            "p4e_layer" => Dict("_supertype" => "AbstractIFEBuildLayer",
                                 "data_type" => "STRUCT_ARRAY",
                                 "documentation" => "user layer"),
            "p4e_layer[:].name" => Dict("data_type" => "STR_0D",
                                         "documentation" => "n",
                                         "type" => "static"),
            "p4e_layer[:].thickness" => Dict("data_type" => "FLT_0D",
                                              "documentation" => "t",
                                              "type" => "static",
                                              "units" => "m"),
            # NESTED marker: this triggers auto-recursion.
            # GenerateDD requires at least one leaf under a STRUCTURE for
            # the struct to be emitted at all — supply r/z so a default
            # `p4e_layer___outline{T}` struct exists for the regex pass to rewrite.
            "p4e_layer[:].outline" => Dict("_supertype" => "AbstractIFEBuildLayerOutline",
                                            "data_type" => "STRUCTURE",
                                            "documentation" => "Nested outline"),
            "p4e_layer[:].outline.r" => Dict("data_type" => "FLT_1D",
                                              "documentation" => "r",
                                              "type" => "static"),
            "p4e_layer[:].outline.z" => Dict("data_type" => "FLT_1D",
                                              "documentation" => "z",
                                              "type" => "static"),
        )
        open(joinpath(sd, "p4e_layer.json"), "w") do io
            JSON.print(io, layer_body, 1)
        end

        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :P4Emit,
            schema_extra_dir = sd,
            slot_bindings = Dict(
                :AbstractIFEBuildLayer        => :p4e_layer,
                :AbstractIFEBuildLayerOutline => :p4e_outline,
            ),
        )

        ids_content = read(result.idstypes_file, String)
        # User layer struct's nested `outline` field type SHOULD be p4e_outline,
        # NOT the user-default `p4e_layer___outline`.
        @test occursin("var\"outline\"::p4e_outline{T}", ids_content)
        @test !occursin("var\"outline\"::p4e_layer___outline{T}", ids_content)
        # The user's nested struct CAN still be emitted (orphan, harmless) —
        # we just must not REFERENCE it from p4e_layer's `outline` field.
        # nested user concrete's _name is `:outline`,
        # not `:_outline` (lstrip applied).
        @test occursin("Symbol(\"outline\")", ids_content)
        @test !occursin("Symbol(\"_outline\")", ids_content)

        # Runtime: load and verify dispatch + nested field type.
        m = load_p2_generated(result, :P4EmitMod)
        d = m.dd()
        push!(d.build.layer, m.p4e_layer{Float64}())
        @test d.build.layer[1] isa m.p4e_layer{Float64}
        @test d.build.layer[1].outline isa m.p4e_outline{Float64}
        @test d.build.layer[1].outline isa IFEdd.AbstractIFEBuildLayerOutline{Float64}
    end

    @testset "no marker = no auto-substitution (opt-in)" begin
        # When the user does NOT declare a nested marker, the nested
        # default emission stays — auto-recursion is strictly opt-in via markers.
        td = mktempdir()
        sd = p2_user_layer_schema(td, "p4e_noauto_layer")
        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :P4NoAuto,
            schema_extra_dir = sd,
            slot_bindings = Dict(:AbstractIFEBuildLayer => :p4e_noauto_layer),
        )
        ids_content = read(result.idstypes_file, String)
        # User concrete is bound, top-level substitution applies, but no
        # nested marker → no auto-recursive entries; the file should NOT
        # contain spurious auto-recursive substitutions for `outline`
        # (the user schema doesn't even have that path).
        @test occursin("mutable struct p4e_noauto_layer{T} <: IFEdd.AbstractIFEBuildLayer{T}",
                       ids_content)
    end

    @testset "triple-underscore default emits clean Symbol" begin
        # Regression guard for the latent bug fixed alongside auto-recursion: when default_concrete ends in `___leaf`, slot_key must
        # be `leaf`, not `_leaf`. Exercises the
        # AbstractIFEDriverBeamEfficiency / driver__beam___efficiency
        # path.
        td = mktempdir()
        sd = p2_user_direct_schema(td, "p4e_eff_slotkey")
        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :P4SlotKey,
            schema_extra_dir = sd,
            slot_bindings = Dict(:AbstractIFEDriverBeamEfficiency => :p4e_eff_slotkey),
        )
        ids_content = read(result.idstypes_file, String)
        # The user concrete's ctor MUST set _name to :efficiency
        # (clean, no leading underscore).
        @test occursin("p4e_eff_slotkey{T}", ids_content)
        # Find the user concrete's _name init line.
        # Before the fix this was `Symbol("_efficiency")`; after, `Symbol("efficiency")`.
        @test !occursin("Symbol(\"_efficiency\")", ids_content)
        # Runtime check: dispatch + _name
        m = load_p2_generated(result, :P4SlotKeyMod)
        d = m.dd()
        push!(d.driver.beam, eltype(fieldtype(typeof(d.driver), :beam))())
        @test getfield(d.driver.beam[1].efficiency, :_name) === :efficiency
    end

    @testset "user concrete _all_info entries are registered" begin
        # user-emitted `(Type, Symbol) => Info(...)` tuples are
        # land in `IMASdd._all_info` via the user module's __init__.
        # Verify: (1) the merge! block is present in the dd file,
        # (2) at runtime, IMASdd lookups find user concrete fields.
        td = mktempdir()
        sd = p2_user_layer_schema(td, "p5e_layer")
        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :P5Emit,
            schema_extra_dir = sd,
            slot_bindings = Dict(:AbstractIFEBuildLayer => :p5e_layer),
        )

        dd_content = read(result.dd_file, String)
        @test occursin("merge!(IMASdd._all_info, Dict{Tuple{<:Type,Symbol},IMASdd.Info}(",
                       dd_content)
        # User concrete fields registered
        @test occursin("(p5e_layer, :name)", dd_content)
        @test occursin("(p5e_layer, :cost)", dd_content)
        @test occursin("(p5e_layer, :thickness)", dd_content)

        # Runtime check: IMASdd._all_info lookup succeeds
        m = load_p2_generated(result, :P5EmitMod)
        @test haskey(IMASdd._all_info, (m.p5e_layer, :name))
        @test haskey(IMASdd._all_info, (m.p5e_layer, :cost))
        # Regen parent IDS also registered
        @test haskey(IMASdd._all_info, (m.build, :layer))
        # Info value is valid
        info_name = IMASdd._all_info[(m.p5e_layer, :name)]
        @test info_name.data_type == "STR_0D"
    end

    @testset "merge! block is empty when no user concretes" begin
        # Edge case: dd that uses only IFEdd defaults (no user concrete
        # bindings) still gets a clean __init__ with no user entries.
        td = mktempdir()
        sd = joinpath(td, "data_structures_extra")
        mkpath(sd)
        # No user schemas at all (defaults-only bake)
        result = IFEdd.generate_user_dd(
            output_dir = joinpath(td, "out"),
            target_module = :P5DefaultsOnly,
            schema_extra_dir = sd,
        )
        dd_content = read(result.dd_file, String)
        # Comment placeholder appears; no merge! call
        @test occursin("(no user concrete _all_info entries to register)",
                       dd_content)
        @test !occursin("merge!(IMASdd._all_info,", dd_content)
    end

    @testset ":parent_schema_missing raises when IFEdd default unavailable" begin
        td = mktempdir()
        sd = p2_user_layer_schema(td, "p2e_pm_layer")
        # Point ifedd_default_schema_dir at a directory WITHOUT build.json
        fake_defaults = mktempdir()
        err = try
            IFEdd.generate_user_dd(
                output_dir = joinpath(td, "out"),
                target_module = :P2EmitPMod,
                schema_extra_dir = sd,
                slot_bindings = Dict(:AbstractIFEBuildLayer => :p2e_pm_layer),
                ifedd_default_schema_dir = fake_defaults,
            )
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :parent_schema_missing
    end

end
