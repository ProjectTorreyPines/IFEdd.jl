using Test
using IFEdd
using IMASdd
using JSON

# Unit tests for the substitution graph builder.
# Mirrors 's worked example as the canonical test vector.

const ABSTRACTS_JSON_PATH_P2 = joinpath(pkgdir(IFEdd), "data_dictionary",
                                       "abstracts.json")

"""
    fake_user_schemas(d::Dict) -> Dict{String,Any}

Synthesizes the in-memory shape `_build_substitution_graph` expects:
the outer dict is keyed by user concrete name, the value is the
parsed-JSON dict that has the concrete name as one of its root keys
(possibly carrying `_supertype`).
"""
function fake_user_schemas(specs::Dict)
    out = Dict{String,Any}()
    for (name, sup) in specs
        root = Dict{String,Any}("documentation" => "fake")
        sup === nothing || (root["_supertype"] = sup)
        out[String(name)] = Dict{String,Any}(String(name) => root)
    end
    return out
end

@testset "substitution graph" begin

    abstracts_blob = JSON.parsefile(ABSTRACTS_JSON_PATH_P2)

    @testset "_derived_top_level_slots returns the 3 IFEdd slots" begin
        slots = IFEdd._derived_top_level_slots(abstracts_blob)
        @test slots == Set([:summary, :build, :driver])
    end

    @testset "_classify_binding_key — top-level slot" begin
        slots = IFEdd._derived_top_level_slots(abstracts_blob)
        valid = Set(Symbol.(keys(abstracts_blob["abstracts"])))
        @test IFEdd._classify_binding_key(:summary, slots, valid) === :top_level_slot
        @test IFEdd._classify_binding_key(:build,   slots, valid) === :top_level_slot
        @test IFEdd._classify_binding_key(:driver,  slots, valid) === :top_level_slot
    end

    @testset "_classify_binding_key — abstract name" begin
        slots = IFEdd._derived_top_level_slots(abstracts_blob)
        valid = Set(Symbol.(keys(abstracts_blob["abstracts"])))
        for a in (:AbstractIFEBuildLayer, :AbstractIFEDriverBeamEfficiency,
                  :AbstractIFESummaryTarget)
            @test IFEdd._classify_binding_key(a, slots, valid) === :abstract_name
        end
    end

    @testset "_classify_binding_key — unknown_abstract_binding" begin
        slots = IFEdd._derived_top_level_slots(abstracts_blob)
        valid = Set(Symbol.(keys(abstracts_blob["abstracts"])))
        err = try
            IFEdd._classify_binding_key(:AbstractIFEFakeThing, slots, valid)
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :unknown_abstract_binding
    end

    @testset "_classify_binding_key — unknown_binding_key" begin
        slots = IFEdd._derived_top_level_slots(abstracts_blob)
        valid = Set(Symbol.(keys(abstracts_blob["abstracts"])))
        err = try
            IFEdd._classify_binding_key(:not_an_abstract_or_slot, slots, valid)
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :unknown_binding_key
    end

    @testset "_classify_kind_from_parent — three valid forms" begin
        @test IFEdd._classify_kind_from_parent("IMASdd.IDStop{T}") == "IDStop"
        @test IFEdd._classify_kind_from_parent("IMASdd.IDS{T}") == "IDS"
        @test IFEdd._classify_kind_from_parent("IMASdd.IDSvectorStaticElement{T}") ==
              "IDSvectorStaticElement"
    end

    @testset "_classify_kind_from_parent — error on unrecognized" begin
        @test_throws ErrorException IFEdd._classify_kind_from_parent("IMASdd.WhatNow{T}")
    end

    @testset "_abstract_for_top_level_slot — invert default_concretes" begin
        @test IFEdd._abstract_for_top_level_slot(:summary, abstracts_blob) == "AbstractIFESummary"
        @test IFEdd._abstract_for_top_level_slot(:build,   abstracts_blob) == "AbstractIFEBuild"
        @test IFEdd._abstract_for_top_level_slot(:driver,  abstracts_blob) == "AbstractIFEDriver"
    end

    @testset "_declared_supertype — reads root marker" begin
        schemas = fake_user_schemas(Dict("my_layer" => "AbstractIFEBuildLayer"))
        @test IFEdd._declared_supertype(schemas["my_layer"]) == "AbstractIFEBuildLayer"
        # Concrete without marker → nothing
        schemas2 = fake_user_schemas(Dict("my_layer" => nothing))
        @test IFEdd._declared_supertype(schemas2["my_layer"]) === nothing
    end

    @testset "_build_substitution_graph — empty bindings → empty graph" begin
        schemas = Dict{String,Any}()
        graph = IFEdd._build_substitution_graph(Dict{Symbol,Symbol}(),
                                                 abstracts_blob, schemas, :Test)
        @test isempty(graph)
    end

    @testset "_build_substitution_graph — single top-level slot" begin
        schemas = fake_user_schemas(Dict("my_summary" => "AbstractIFESummary"))
        graph = IFEdd._build_substitution_graph(
            Dict(:summary => :my_summary),
            abstracts_blob, schemas, :GraphTest1)
        @test length(graph) == 1
        @test haskey(graph, "summary")
        e = graph["summary"]
        @test e.user_concrete == "my_summary"
        @test e.abstract      == "AbstractIFESummary"
        @test e.parent_kind   == "IDStop"
        @test e.source_key    === :summary
    end

    @testset "_build_substitution_graph — single sub-IDS" begin
        schemas = fake_user_schemas(Dict("my_layer" => "AbstractIFEBuildLayer"))
        graph = IFEdd._build_substitution_graph(
            Dict(:AbstractIFEBuildLayer => :my_layer),
            abstracts_blob, schemas, :GraphTest2)
        @test length(graph) == 1
        @test haskey(graph, "build__layer")
        e = graph["build__layer"]
        @test e.user_concrete == "my_layer"
        @test e.abstract      == "AbstractIFEBuildLayer"
        @test e.parent_kind   == "IDSvectorStaticElement"
        @test e.source_key    === :AbstractIFEBuildLayer
    end

    @testset "_build_substitution_graph —  worked example" begin
        schemas = fake_user_schemas(Dict(
            "my_summary"    => "AbstractIFESummary",
            "my_layer"      => "AbstractIFEBuildLayer",
            "my_efficiency" => "AbstractIFEDriverBeamEfficiency",
        ))
        graph = IFEdd._build_substitution_graph(
            Dict(:summary                         => :my_summary,
                 :AbstractIFEBuildLayer           => :my_layer,
                 :AbstractIFEDriverBeamEfficiency => :my_efficiency),
            abstracts_blob, schemas, :Worked)
        @test length(graph) == 3
        @test graph["summary"].user_concrete == "my_summary"
        @test graph["summary"].parent_kind   == "IDStop"
        @test graph["build__layer"].user_concrete == "my_layer"
        @test graph["build__layer"].parent_kind   == "IDSvectorStaticElement"
        @test graph["driver__beam___efficiency"].user_concrete == "my_efficiency"
        @test graph["driver__beam___efficiency"].parent_kind   == "IDS"
    end

    @testset ":slot_key_collision — same slot via both forms" begin
        schemas = fake_user_schemas(Dict(
            "my_summary"       => "AbstractIFESummary",
            "my_other_summary" => "AbstractIFESummary",
        ))
        err = try
            IFEdd._build_substitution_graph(
                Dict(:summary            => :my_summary,
                     :AbstractIFESummary => :my_other_summary),
                abstracts_blob, schemas, :Collide)
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :slot_key_collision
    end

    @testset ":concrete_not_in_schemas — binding points at missing concrete" begin
        schemas = fake_user_schemas(Dict{String,Union{String,Nothing}}())
        err = try
            IFEdd._build_substitution_graph(
                Dict(:AbstractIFEBuildLayer => :no_such_concrete),
                abstracts_blob, schemas, :NoConcrete)
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :concrete_not_in_schemas
    end

    @testset ":binding_marker_mismatch — user marker disagrees with bound abstract" begin
        # User declares my_layer <: AbstractIFEDriverBeam BUT binds it to AbstractIFEBuildLayer
        schemas = fake_user_schemas(Dict("my_layer" => "AbstractIFEDriverBeam"))
        err = try
            IFEdd._build_substitution_graph(
                Dict(:AbstractIFEBuildLayer => :my_layer),
                abstracts_blob, schemas, :Mismatch)
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :binding_marker_mismatch
    end

    @testset "user concrete without _supertype marker is allowed (no validation)" begin
        # The marker is optional; absence means the validation skips.
        schemas = fake_user_schemas(Dict("my_layer" => nothing))
        graph = IFEdd._build_substitution_graph(
            Dict(:AbstractIFEBuildLayer => :my_layer),
            abstracts_blob, schemas, :NoMarker)
        @test length(graph) == 1
        @test graph["build__layer"].user_concrete == "my_layer"
    end

    @testset "mixed slot + abstract bindings coexist" begin
        schemas = fake_user_schemas(Dict(
            "my_summary"  => "AbstractIFESummary",
            "my_layer"    => "AbstractIFEBuildLayer",
        ))
        graph = IFEdd._build_substitution_graph(
            Dict(:summary               => :my_summary,
                 :AbstractIFEBuildLayer => :my_layer),
            abstracts_blob, schemas, :Mix)
        @test length(graph) == 2
        @test graph["summary"].source_key    === :summary
        @test graph["build__layer"].source_key === :AbstractIFEBuildLayer
    end

    # ────────────────────────────────────────────────────────────────────
    # shared abstracts (tuple-key + nested-dict forms)
    # ────────────────────────────────────────────────────────────────────

    @testset "nested-dict form: nested-dict binding for shared abstract" begin
        schemas = fake_user_schemas(Dict(
            "my_summary_code" => "AbstractIDSCode",
            "my_build_code"   => "AbstractIDSCode",
        ))
        graph = IFEdd._build_substitution_graph(
            Dict(:AbstractIDSCode => Dict(:summary => :my_summary_code,
                                           :build   => :my_build_code)),
            abstracts_blob, schemas, :F2)
        @test length(graph) == 2
        @test haskey(graph, "summary__code")
        @test haskey(graph, "build__code")
        @test graph["summary__code"].user_concrete == "my_summary_code"
        @test graph["build__code"].user_concrete   == "my_build_code"
        @test graph["summary__code"].abstract == "AbstractIDSCode"
        # source_key for F2 is (abs_sym, path_sym) per 
        @test graph["summary__code"].source_key == (:AbstractIDSCode, :summary)
    end

    @testset "tuple-key form: tuple-key binding for shared abstract" begin
        schemas = fake_user_schemas(Dict(
            "my_summary_code" => "AbstractIDSCode",
        ))
        graph = IFEdd._build_substitution_graph(
            Dict((:AbstractIDSCode, :summary) => :my_summary_code),
            abstracts_blob, schemas, :F1)
        @test length(graph) == 1
        @test haskey(graph, "summary__code")
        @test graph["summary__code"].user_concrete == "my_summary_code"
        # source_key for F1 is the tuple itself
        @test graph["summary__code"].source_key == (:AbstractIDSCode, :summary)
    end

    @testset "bare Symbol form on shared abstract raises :shared_abstract_needs_path" begin
        schemas = fake_user_schemas(Dict("my_code" => "AbstractIDSCode"))
        err = try
            IFEdd._build_substitution_graph(
                Dict(:AbstractIDSCode => :my_code),     # ambiguous!
                abstracts_blob, schemas, :SharedNeedsPath)
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :shared_abstract_needs_path
    end

    @testset "bad path raises :shared_abstract_path_not_found" begin
        schemas = fake_user_schemas(Dict("my_code" => "AbstractIDSCode"))
        err = try
            IFEdd._build_substitution_graph(
                Dict((:AbstractIDSCode, :nonexistent_host) => :my_code),
                abstracts_blob, schemas, :BadPath)
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :shared_abstract_path_not_found
    end

    @testset "empty nested-dict inner Dict raises :shared_abstract_empty_binding" begin
        schemas = fake_user_schemas(Dict{String,Union{String,Nothing}}())
        err = try
            IFEdd._build_substitution_graph(
                Dict(:AbstractIDSCode => Dict{Symbol,Symbol}()),
                abstracts_blob, schemas, :Empty)
            nothing
        catch e; e end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :shared_abstract_empty_binding
    end

    @testset "mixed nested-dict + slot + single-default in one Dict" begin
        schemas = fake_user_schemas(Dict(
            "my_summary"      => "AbstractIFESummary",
            "my_layer"        => "AbstractIFEBuildLayer",
            "my_summary_code" => "AbstractIDSCode",
        ))
        graph = IFEdd._build_substitution_graph(
            Dict(:summary                  => :my_summary,        # 
                 :AbstractIFEBuildLayer    => :my_layer,          # abstract, single default
                 :AbstractIDSCode          => Dict(:summary => :my_summary_code)),  # nested-dict form
            abstracts_blob, schemas, :Mixed)
        @test length(graph) == 3
        @test haskey(graph, "summary")
        @test haskey(graph, "build__layer")
        @test haskey(graph, "summary__code")
    end

end
