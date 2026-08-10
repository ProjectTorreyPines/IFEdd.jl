using Test
using IFEdd
using IMASdd
using JSON

# Runs `examples/custom_build_layer/` end to end, so the published example
# cannot rot against changes to `build.json`, `abstracts.json` or the emitter.

@testset "examples/custom_build_layer" begin
    example_dir = joinpath(pkgdir(IFEdd), "examples", "custom_build_layer")
    schema_dir = joinpath(example_dir, "data_dictionary", "data_structures_extra")

    @testset "schema stays a superset of IFEdd's build.layer" begin
        # The example's whole point is that a substituted type inherits nothing.
        # If IFEdd grows a `build.layer` field and the example is not updated,
        # the example silently starts dropping it — catch that here.
        default_paths = Set(
            replace(p, "build.layer" => "my_layer")
            for p in keys(JSON.parsefile(joinpath(pkgdir(IFEdd), "data_dictionary",
                                                  "data_structures_extra", "build.json")))
            if startswith(p, "build.layer")
        )
        example_paths = Set(keys(JSON.parsefile(joinpath(schema_dir, "my_layer.json"))))

        @test isempty(setdiff(default_paths, example_paths))
        @test "my_layer[:].cost_rate" in setdiff(example_paths, default_paths)
    end

    @testset "runs and substitutes" begin
        script = joinpath(example_dir, "run.jl")
        sandbox = Module(:CustomLayerExample)
        Core.eval(sandbox, :(const IFEdd = $IFEdd))
        @test (Base.include(sandbox, script); true)

        MyDD = getfield(sandbox, :MyDD)
        types = getfield(sandbox, :MyTypes)

        dd = Base.invokelatest(MyDD)
        @test dd isa IFEdd.AbstractIFEDD{Float64}
        @test dd isa IMASdd.DD{Float64}
        @test eltype(dd.build.layer) === types.my_layer{Float64}
        @test types.my_layer{Float64} <: IFEdd.AbstractIFEBuildLayer{Float64}
        @test hasfield(types.my_layer{Float64}, :cost_rate)
        @test hasfield(types.my_layer{Float64}, :material)   # inherited only by copy

        # substitution is per-bake: IFEdd's own container is untouched
        @test fieldtype(IFEdd.build{Float64}, :layer) ===
              IMASdd.IDSvector{IFEdd.build__layer{Float64}}
    end
end
