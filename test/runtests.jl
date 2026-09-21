using Test
using IFEdd
using IMASdd
using HelpPlots

include("test_abstracts_derive.jl")    # abstracts.json drift — runs FIRST
include("test_abstracts.jl")
include("test_supertype_emission.jl")  # supertype emission invariant
include("test_no_top_level_all_info_reads.jl")
include("test_shared_helpers.jl")
include("test_user_dd_emit.jl")
include("test_user_dd_fixture.jl")
include("test_bake_dd_macro.jl")
include("test_substitution_graph.jl")  # substitution graph builder units
include("test_substitution_regex.jl")  # regex pass against a canonical fragment
include("test_substitution_emission.jl")  # end-to-end substitution + dispatch
include("test_subids_fixture.jl")      # sub-IDS fixture byte-equal gate
include("test_example_custom_layer.jl")   # published example stays runnable
include("test_plots_ext.jl")              # Plots recipes — must work without IMAS

@testset "IFEdd" begin

    @testset "Module loading" begin
        @test isdefined(IFEdd, :dd)
        @test isdefined(IFEdd, :summary)
        @test isdefined(IFEdd, :build)
        @test isdefined(IFEdd, :driver)
    end

    @testset "Type hierarchy" begin
        # dd → AbstractIFEDD → IMASdd.DD, with the middle link a real one
        @test typeof(IFEdd.dd()) <: IFEdd.AbstractIFEDD{Float64}
        @test IFEdd.AbstractIFEDD{Float64} <: IMASdd.DD{Float64}
        @test supertype(IFEdd.dd{Float64}) === IFEdd.AbstractIFEDD{Float64}
        @test isabstracttype(IFEdd.AbstractIFEDD)
        # IMASdd's own container is a sibling, not an IFE container
        @test !(IMASdd.dd{Float64} <: IFEdd.AbstractIFEDD)

        @test IFEdd.dd{Float64} <: IMASdd.DD{Float64}
        @test IFEdd.dd{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.summary{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.build{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.driver{Float64} <: IMASdd.IDS{Float64}
    end

    @testset "Instantiation" begin
        d = IFEdd.dd()
        @test d isa IFEdd.dd{Float64}
        @test d isa IMASdd.DD{Float64}

        # Parametric construction
        d32 = IFEdd.dd{Float32}()
        @test d32 isa IFEdd.dd{Float32}

        # IFE-specific IDS children
        @test d.summary isa IFEdd.summary{Float64}
        @test d.build isa IFEdd.build{Float64}
        @test d.driver isa IFEdd.driver{Float64}

        # Mode B subset: standard IDS reused from IMASdd (not regenerated)
        @test d.pellets isa IMASdd.pellets{Float64}
        @test d.core_profiles isa IMASdd.core_profiles{Float64}
        @test d.core_sources isa IMASdd.core_sources{Float64}
        @test d.blanket isa IMASdd.blanket{Float64}
        @test d.neutronics isa IMASdd.neutronics{Float64}
        @test d.balance_of_plant isa IMASdd.balance_of_plant{Float64}
        @test d.costing isa IMASdd.costing{Float64}
        @test d.requirements isa IMASdd.requirements{Float64}
    end

    @testset "_all_info registration" begin
        # Top-level container entries
        @test haskey(IMASdd._all_info, (IFEdd.dd, :summary))
        @test haskey(IMASdd._all_info, (IFEdd.dd, :build))
        @test haskey(IMASdd._all_info, (IFEdd.dd, :driver))

        # A leaf field
        @test haskey(IMASdd._all_info, (IFEdd.summary, :target))

        info = IMASdd._all_info[(IFEdd.dd, :summary)]
        @test info isa IMASdd.Info
        @test info.data_type == "STRUCTURE"
    end

    @testset "IMASdd machinery compatibility" begin
        d = IFEdd.dd()

        # isfrozen dispatches on abstract ::IDS, must work without overrides
        @test IMASdd.isfrozen(d) == false

        df = IFEdd.dd(; frozen=true)
        @test IMASdd.isfrozen(df) == true

        # parent traversal: a leaf's _parent should point back to dd
        @test getfield(d.summary, :_parent).value === d
    end

end
