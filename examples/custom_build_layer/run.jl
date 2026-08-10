# Substituting a custom chamber layer into the IFE build.
#
#     julia --project=. examples/custom_build_layer/run.jl
#
# `data_dictionary/data_structures_extra/my_layer.json` is IFEdd's own
# `build.layer` schema, copied verbatim and extended with one field
# (`cost_rate`). The copy is the point: a substituted type inherits nothing,
# so whatever the schema does not list simply does not exist.

using IFEdd

const SCHEMA_DIR = joinpath(@__DIR__, "data_dictionary", "data_structures_extra")

IFEdd.@bake_dd MyDD = (
    schema_dir    = SCHEMA_DIR,
    slot_bindings = Dict(:AbstractIFEBuildLayer => :my_layer),
)

const MyTypes = parentmodule(MyDD)

# Payload fields only: drop housekeeping (`_name`, ...) and the `_σ`
# uncertainty companions the generator adds for every float.
payload(T) = sort([f for f in fieldnames(T)
                   if !startswith(string(f), "_") && !endswith(string(f), "_σ")])

default_fields = payload(IFEdd.build__layer{Float64})
custom_fields = payload(MyTypes.my_layer{Float64})

println("kept  : ", intersect(default_fields, custom_fields))
println("added : ", setdiff(custom_fields, default_fields))
println("lost  : ", setdiff(default_fields, custom_fields))

dd = MyDD()

layer = MyTypes.my_layer{Float64}()
layer.name = "first_wall"
layer.material = "tungsten"
layer.volume = 3.4
layer.cost_rate = 1200.0
push!(dd.build.layer, layer)

println()
println("build.layer eltype : ", eltype(dd.build.layer))
println("dispatches as IFE  : ", dd.build.layer[1] isa IFEdd.AbstractIFEBuildLayer)

# Nested structures are re-emitted under the customized names too, because the
# copied schema carried its `_supertype` marker down with it. Same fields, same
# abstract, different identity.
outline = typeof(dd.build.layer[1].outline)
println("outline type       : ", outline)
println("  <: the abstract  : ", outline <: IFEdd.AbstractIFEBuildLayerOutline)
println("  === IFEdd's      : ", outline === IFEdd.build__layer___outline{Float64})

# Substitution is per-bake. IFEdd's own container never changes.
println()
println("IFEdd.dd untouched : ", fieldtype(IFEdd.build{Float64}, :layer))
