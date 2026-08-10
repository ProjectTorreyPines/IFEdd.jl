using Test
using IFEdd
using IMASdd
using JSON

# `abstracts.json` is the single source of truth for the abstract lattice.
# Every test below treats the JSON as authoritative and asserts that the
# loaded `IFEdd` module matches it.
#
# lattice has 8 abstracts; abstracts.json is now a
# derived lockfile produced by `scripts/derive_abstracts.jl`. The
# byte-equality drift check lives in `test_abstracts_derive.jl`.

const ABSTRACTS_JSON_PATH = joinpath(pkgdir(IFEdd), "data_dictionary",
                                    "abstracts.json")

# Per-abstract parent expectation (set by hand, mirrored by classify_parent
# at derive time). Used to keep the per-entry parent assertion explicit
# rather than re-deriving in the test.
const EXPECTED_PARENTS = Dict{String,String}(
    # 8 per-IDS abstracts
    "AbstractIFESummary"              => "IMASdd.IDStop{T}",
    "AbstractIFEBuild"                => "IMASdd.IDStop{T}",
    "AbstractIFEDriver"               => "IMASdd.IDStop{T}",
    "AbstractIFESummaryTarget"        => "IMASdd.IDS{T}",
    "AbstractIFEBuildLayer"           => "IMASdd.IDSvectorStaticElement{T}",
    "AbstractIFEBuildLayerOutline"    => "IMASdd.IDS{T}",
    "AbstractIFEDriverBeam"           => "IMASdd.IDSvectorStaticElement{T}",
    "AbstractIFEDriverBeamEfficiency" => "IMASdd.IDS{T}",
    # 5 shared cross-IDS abstracts
    "AbstractIDSCode"                 => "IMASdd.IDS{T}",
    "AbstractIDSCodeLibrary"          => "IMASdd.IDSvectorStaticElement{T}",
    "AbstractIDSProperties"           => "IMASdd.IDS{T}",
    "AbstractIDSPropertiesPlugins"    => "IMASdd.IDS{T}",
    "AbstractIDSPropertiesProvenance" => "IMASdd.IDS{T}",
)

@testset "abstracts.json" begin

    @testset "abstracts.json round-trips" begin
        @test isfile(ABSTRACTS_JSON_PATH)
        raw = JSON.parsefile(ABSTRACTS_JSON_PATH)
        @test haskey(raw, "version")
        @test haskey(raw, "abstracts")
        @test haskey(raw, "default_concretes")
        @test haskey(raw, "_derived_from")
        @test raw["version"] == "3.0.0"
        @test raw["_derived_from"] == "scripts/derive_abstracts.jl"
        @test length(raw["abstracts"]) == 13
        @test length(raw["default_concretes"]) == 13
        # Reparse from a serialized copy and confirm structural equality
        io = IOBuffer()
        JSON.print(io, raw)
        round = JSON.parse(String(take!(io)))
        @test round == raw
    end

    @testset "abstracts in JSON match abstracts in module" begin
        raw = JSON.parsefile(ABSTRACTS_JSON_PATH)
        for (name, spec) in raw["abstracts"]
            sym = Symbol(name)
            @test isdefined(IFEdd, sym)
            T = getfield(IFEdd, sym)
            @test T isa UnionAll
            # All abstracts subtype IMASdd.IDS (the root); top-level ones
            # subtype IDStop; element-type abstracts subtype
            # IDSvectorStaticElement (which itself is a subtype of IDS).
            @test T{Float64} <: IMASdd.IDS{Float64}
            @test spec["param"] == ["T"]
            # Per-entry parent expectation (mirrors classify_parent).
            @test haskey(EXPECTED_PARENTS, name)
            @test spec["parent"] == EXPECTED_PARENTS[name]
        end
    end

    @testset "default concretes resolve, subtype the declared abstract" begin
        # default_concretes is nested —
        # `abs_name → parent_path → concrete`. Iterate every (abs, path).
        raw = JSON.parsefile(ABSTRACTS_JSON_PATH)
        for (abs_name, inner) in raw["default_concretes"]
            asym = Symbol(abs_name)
            @test isdefined(IFEdd, asym)
            A = getfield(IFEdd, asym)
            for (parent_path, concrete_name) in inner
                csym = Symbol(concrete_name)
                @test isdefined(IFEdd, csym)
                C = getfield(IFEdd, csym)
                @test C isa UnionAll
                # Concrete subtypes its declared abstract
                @test supertype(C{Float64}) === A{Float64}
            end
        end
    end

    @testset "FILLED_FIELDS_PREFIX pinned" begin
        @test IFEdd.FILLED_FIELDS_PREFIX == "FilledFields____"
    end

    @testset "all 8 abstract types are defined and parametric" begin
        for name in ("AbstractIFESummary", "AbstractIFEBuild", "AbstractIFEDriver",
                     "AbstractIFESummaryTarget", "AbstractIFEBuildLayer",
                     "AbstractIFEBuildLayerOutline", "AbstractIFEDriverBeam",
                     "AbstractIFEDriverBeamEfficiency")
            sym = Symbol(name)
            @test isdefined(IFEdd, sym)
            T = getfield(IFEdd, sym)
            @test T isa UnionAll
            @test T{Float64} <: IMASdd.IDS{Float64}
        end
        # Top-level marker chain
        @test IFEdd.AbstractIFESummary{Float64} <: IMASdd.IDStop{Float64}
        @test IFEdd.AbstractIFEBuild{Float64}   <: IMASdd.IDStop{Float64}
        @test IFEdd.AbstractIFEDriver{Float64}  <: IMASdd.IDStop{Float64}
        # IDSvector element chain
        @test IFEdd.AbstractIFEBuildLayer{Float64} <: IMASdd.IDSvectorStaticElement{Float64}
        @test IFEdd.AbstractIFEDriverBeam{Float64} <: IMASdd.IDSvectorStaticElement{Float64}
    end

    @testset "default concretes — full supertype chain" begin
        # Top-level
        @test IFEdd.summary{Float64} <: IFEdd.AbstractIFESummary{Float64}
        @test IFEdd.build{Float64}   <: IFEdd.AbstractIFEBuild{Float64}
        @test IFEdd.driver{Float64}  <: IFEdd.AbstractIFEDriver{Float64}
        @test IFEdd.summary{Float64} <: IMASdd.IDStop{Float64}
        # 5 new nested concretes
        @test IFEdd.summary__target{Float64} <: IFEdd.AbstractIFESummaryTarget{Float64}
        @test IFEdd.build__layer{Float64} <: IFEdd.AbstractIFEBuildLayer{Float64}
        @test IFEdd.build__layer___outline{Float64} <: IFEdd.AbstractIFEBuildLayerOutline{Float64}
        @test IFEdd.driver__beam{Float64} <: IFEdd.AbstractIFEDriverBeam{Float64}
        @test IFEdd.driver__beam___efficiency{Float64} <: IFEdd.AbstractIFEDriverBeamEfficiency{Float64}
        # IDSvector elements transitively cover IDSvectorElement
        @test IFEdd.build__layer{Float64} <: IMASdd.IDSvectorStaticElement{Float64}
        @test IFEdd.driver__beam{Float64} <: IMASdd.IDSvectorStaticElement{Float64}
    end

end
