using Test
using IFEdd
using IMASdd
using IMAS
using FUSE

@testset "IFEdd" begin

    @testset "Module loading" begin
        @test isdefined(IFEdd, :dd_ife)
        @test isdefined(IFEdd, :ife_summary)
        @test isdefined(IFEdd, :ife_build)
        @test isdefined(IFEdd, :ife_driver)
    end

    @testset "Type hierarchy" begin
        @test IFEdd.dd_ife{Float64} <: IMASdd.DD{Float64}
        @test IFEdd.dd_ife{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.ife_summary{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.ife_build{Float64} <: IMASdd.IDS{Float64}
        @test IFEdd.ife_driver{Float64} <: IMASdd.IDS{Float64}
    end

    @testset "Instantiation" begin
        d = IFEdd.dd_ife()
        @test d isa IFEdd.dd_ife{Float64}
        @test d isa IMASdd.DD{Float64}

        # Parametric construction
        d32 = IFEdd.dd_ife{Float32}()
        @test d32 isa IFEdd.dd_ife{Float32}

        # Children are real concrete IDS structs
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
        @test haskey(IMASdd._all_info, (IFEdd.dd_ife, :ife_summary))
        @test haskey(IMASdd._all_info, (IFEdd.dd_ife, :ife_build))
        @test haskey(IMASdd._all_info, (IFEdd.dd_ife, :ife_driver))

        # A leaf field
        @test haskey(IMASdd._all_info, (IFEdd.ife_summary, :target))

        info = IMASdd._all_info[(IFEdd.dd_ife, :ife_summary)]
        @test info isa IMASdd.Info
        @test info.data_type == "STRUCTURE"
    end

    @testset "IMASdd machinery compatibility" begin
        d = IFEdd.dd_ife()

        # isfrozen dispatches on abstract ::IDS, must work without overrides
        @test IMASdd.isfrozen(d) == false

        df = IFEdd.dd_ife(; frozen=true)
        @test IMASdd.isfrozen(df) == true

        # parent traversal: a leaf's _parent should point back to dd_ife
        @test getfield(d.ife_summary, :_parent).value === d
    end

    @testset "Ported IFE modules — symbols exposed" begin
        # Actors
        @test isdefined(IFEdd, :ActorIFEAblation)
        @test isdefined(IFEdd, :FUSEparameters__ActorIFEAblation)
        @test isdefined(IFEdd, :ActorIFEBlanket)
        @test isdefined(IFEdd, :FUSEparameters__ActorIFEBlanket)

        # Extract
        @test isdefined(IFEdd, :ife_duty_cycle)
        @test isdefined(IFEdd, :extract_ife)

        # Plot recipes live in IFEddPlotsExt (weakdep extension);
        # activated only when `using Plots`. Not tested here to keep
        # core test suite light.
    end

    @testset "ife_duty_cycle — IFE-only computation" begin
        d = IFEdd.dd_ife()
        # Empty driver returns NaN
        @test isnan(IFEdd.ife_duty_cycle(d))
    end

    @testset "Actor parameter structs instantiate" begin
        par_ablation = IFEdd.FUSEparameters__ActorIFEAblation{Float64}()
        @test par_ablation isa FUSE.ParametersActor{Float64}

        par_blanket = IFEdd.FUSEparameters__ActorIFEBlanket{Float64}()
        @test par_blanket isa FUSE.ParametersActor{Float64}
    end

    @testset "IMAS function dispatch on dd_ife (Phase 2 signature relaxation)" begin
        d = IFEdd.dd_ife()
        # fusion_power / fusion_neutron_power / fusion_energy must accept dd_ife
        # after IMAS-side signature relaxation (::IMAS.dd → ::IMAS.DD).
        @test which(IMAS.fusion_power, (typeof(d),)) isa Method
        @test which(IMAS.fusion_neutron_power, (typeof(d),)) isa Method
        @test which(IMAS.fusion_energy, (typeof(d),)) isa Method

        # And the standard IMAS.dd dispatch must still work (no regression).
        std_dd = IMAS.dd()
        @test which(IMAS.fusion_power, (typeof(std_dd),)) isa Method
    end

    @testset "extract_ife stub — two-container signature" begin
        dd = IMAS.dd()
        ife = IFEdd.dd_ife()
        out = IFEdd.extract_ife(dd, ife)
        @test out isa AbstractDict
        @test haskey(out, :duty_cycle)
        @test isnan(out[:duty_cycle])  # empty driver
    end

end
