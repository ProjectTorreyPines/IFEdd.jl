using Test
using MyIFEProject
using IFEdd
using IMASdd

@testset "MyIFEProject fixture" begin
    d = MyIFEProject.dd()
    @test d isa IMASdd.DD{Float64}
    @test d.summary isa MyIFEProject.my_summary{Float64}
    @test d.summary isa IFEdd.AbstractIFESummary{Float64}

    # depth-1 round-trip
    d.summary.yield = 7.0
    @test d.summary.yield == 7.0

    # depth-2 round-trip exercises nested struct emission
    @test d.summary.beam isa MyIFEProject.my_summary__beam{Float64}
    d.summary.beam.energy = 1.5e6
    @test d.summary.beam.energy == 1.5e6
end
