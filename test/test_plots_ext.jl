# Plots extension: recipes for the IFE-owned IDS.
#
# The whole point of this file is that it runs WITHOUT IMAS. IMAS is not a test
# dependency, so if a recipe ever reaches for it again, these tests fail rather
# than the extension silently going missing for `using IFEdd, Plots` users.

using Plots

"""
    demo_dd() -> IFEdd.dd

A chamber with three build layers, two driver beams and a two-shell capsule —
enough for every recipe to emit its full set of series.
"""
function demo_dd()
    dd = IFEdd.dd()
    dd.global_time = 0.0

    resize!(dd.build.layer, 3)
    for (i, (name, type, r0, r1)) in enumerate((
        ("chamber", -1, 0.0, 5.0),
        ("first wall", 5, 5.0, 5.2),
        ("blanket", 4, 5.2, 6.0)))
        layer = dd.build.layer[i]
        layer.name = name
        layer.type = type
        layer.start_radius = r0
        layer.end_radius = r1
        layer.thickness = r1 - r0
    end

    # `power_launched` is a time series: IMASdd refuses the assignment until its
    # coordinate `driver.time` exists.
    dd.driver.time = [0.0]
    resize!(dd.driver.beam, 2)
    for beam in dd.driver.beam
        beam.power_launched = [1.0e6]
        beam.efficiency.conversion = 0.1
        beam.efficiency.coupling = 0.85
    end

    resize!(dd.pellets.launcher, 1)
    dd.pellets.launcher[1].shape.size = [2.0e-3]
    resize!(dd.pellets.time_slice, 1)
    dd.pellets.time_slice[1].time = 0.0
    resize!(dd.pellets.time_slice[1].pellet, 1)
    resize!(dd.pellets.time_slice[1].pellet[1].layer, 1)
    ablator = dd.pellets.time_slice[1].pellet[1].layer[1]
    ablator.thickness = 0.5e-3
    resize!(ablator.species, 1)
    ablator.species[1].label = "DT"

    return dd
end

nseries(p) = length(p.series_list)

@testset "Plots extension" begin

    @testset "loads on Plots alone" begin
        # The regression this file exists for: the extension used to be declared
        # as `["Plots", "IMAS"]`, an AND, so `using IFEdd, Plots` silently got
        # no recipes at all.
        @test Base.get_extension(IFEdd, :IFEddPlotsExt) !== nothing
        @test !haskey(Base.loaded_modules, Base.PkgId(
            Base.UUID("13ead8c1-b7d1-41bb-a6d0-5b8b65ed587a"), "IMAS"))
    end

    dd = demo_dd()

    @testset "build" begin
        # cross-section: one filled circle per layer, outermost first
        @test nseries(plot(dd.build)) == 3
        @test nseries(plot(dd.build.layer)) == 3
        # radial bar chart: a span plus a boundary line per layer
        @test nseries(plot(dd.build; cx=false)) == 6

        # gaps are drawn but never labelled; named layers are
        gap = IFEdd.dd()
        resize!(gap.build.layer, 1)
        gap.build.layer[1].name = "void"
        gap.build.layer[1].type = 0
        ext = Base.get_extension(IFEdd, :IFEddPlotsExt)
        @test ext.layer_attrs(gap.build.layer[1]) == ("", :white)
        @test ext.layer_attrs(dd.build.layer[2]) == ("first wall", :yellow)
    end

    @testset "driver" begin
        p = plot(dd.driver)
        # `:bar` expands into two Plots series: the filled bars plus their markers
        @test nseries(p) == 2
        # wall plug > launched > absorbed, in MW: 2 beams × 1 MW launched,
        # η_conversion = 0.1, η_coupling = 0.85
        levels = only(s[:y] for s in p.series_list if s[:seriestype] === :scatter)
        @test levels ≈ [20.0, 2.0, 1.7]

        # With no beams the recipe must emit nothing. A bare `return` inside a
        # `@recipe` body does not do this — it leaves the `@series` below it
        # live, which used to plot a bar chart of zeros.
        @test nseries(plot(IFEdd.dd().driver)) == 0
    end

    @testset "chamber overview" begin
        # 3 layers + 2 beams + 2 capsule shells (ablator and hot spot)
        @test nseries(plot(dd)) == 7

        # the capsule is optional; without it only layers and beams are drawn
        bare = demo_dd()
        empty!(bare.pellets.launcher)
        @test nseries(plot(bare)) == 5

        # an empty build draws nothing rather than indexing off the end
        @test nseries(plot(IFEdd.dd())) == 0
    end

    @testset "capsule shells scale to the display radius" begin
        ext = Base.get_extension(IFEdd, :IFEddPlotsExt)
        shells = ext.target_shells(dd.pellets, 1.0)
        @test length(shells) == 2
        @test shells[1].lbl == "hot spot"
        @test shells[2].lbl == "DT"
        @test shells[2].r_out ≈ 1.0                  # outermost hits the display radius
        @test shells[2].r_in ≈ 1.0 - 0.5 / 2.0       # 0.5 mm shell of a 2 mm capsule
        @test shells[1].r_out ≈ shells[2].r_in       # shells are contiguous
    end

    @testset "recipe_dispatch reports IDS paths" begin
        # help_plot output should read "build", not "IFEdd.build{Float64}"
        @test HelpPlots.recipe_dispatch(dd.build) == "build"
        @test HelpPlots.recipe_dispatch(dd.driver) == "driver"
        @test HelpPlots.recipe_dispatch(dd.build.layer) == "build.layer"
        @test HelpPlots.recipe_dispatch(dd) == "dd"
    end

end
