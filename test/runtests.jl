using Test
using IFEdd
using IMASdd

@testset "IFEdd" begin

    @testset "Module loading" begin
        @test isdefined(IFEdd, :dd)
        @test isdefined(IFEdd, :ife_summary)
        @test isdefined(IFEdd, :ife_build)
        @test isdefined(IFEdd, :ife_driver)
    end

    @testset "Type hierarchy" begin
        @test IFEdd.dd{Float64} <: IMASdd.DD{Float64}
        @test IFEdd.dd{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.ife_summary{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.ife_build{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.ife_driver{Float64} <: IMASdd.IDS{Float64}
    end

    @testset "Instantiation" begin
        d = IFEdd.dd()
        @test d isa IFEdd.dd{Float64}
        @test d isa IMASdd.DD{Float64}

        # Parametric construction
        d32 = IFEdd.dd{Float32}()
        @test d32 isa IFEdd.dd{Float32}

        # IFE-specific IDS children
        @test d.ife_summary isa IFEdd.ife_summary{Float64}
        @test d.ife_build isa IFEdd.ife_build{Float64}
        @test d.ife_driver isa IFEdd.ife_driver{Float64}

        # Mode B subset: standard IDS reused from IMASdd (not regenerated)
        @test d.pellets isa IMASdd.pellets{Float64}
        @test d.core_profiles isa IMASdd.core_profiles{Float64}
        @test d.core_sources isa IMASdd.core_sources{Float64}
        @test d.blanket isa IMASdd.blanket{Float64}
        @test d.neutronics isa IMASdd.neutronics{Float64}
        @test d.balance_of_plant isa IMASdd.balance_of_plant{Float64}
        @test d.costing isa IMASdd.costing{Float64}
        @test d.requirements isa IMASdd.requirements{Float64}
        @test d.summary isa IMASdd.summary{Float64}
    end

    @testset "_all_info registration" begin
        # Top-level container entries
        @test haskey(IMASdd._all_info, (IFEdd.dd, :ife_summary))
        @test haskey(IMASdd._all_info, (IFEdd.dd, :ife_build))
        @test haskey(IMASdd._all_info, (IFEdd.dd, :ife_driver))

        # A leaf field
        @test haskey(IMASdd._all_info, (IFEdd.ife_summary, :target))

        info = IMASdd._all_info[(IFEdd.dd, :ife_summary)]
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
        @test getfield(d.ife_summary, :_parent).value === d
    end

end
