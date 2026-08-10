# Worked example

A runnable version of everything on the previous pages lives in the repository at
[`examples/custom_build_layer/`](https://github.com/ProjectTorreyPines/IFEdd.jl/tree/master/examples/custom_build_layer):

```
examples/custom_build_layer/
├── data_dictionary/data_structures_extra/
│   └── my_layer.json
└── run.jl
```

```bash
julia --project=. examples/custom_build_layer/run.jl
```

It substitutes a custom chamber layer — IFEdd's own `build.layer`, extended with a
per-volume `cost_rate` — and reports exactly what the substituted type ended up with.

## A substituted type inherits nothing

This is the part worth internalizing. `my_layer.json` is IFEdd's `build.layer` schema
**copied in full**, plus one new entry:

```json
"my_layer": {
  "_supertype": "AbstractIFEBuildLayer",
  "data_type": "STRUCT_ARRAY",
  "documentation": "Chamber layer, copied from IFEdd's `build.layer` and extended with `cost_rate`"
},
"my_layer[:].cost_rate": {
  "data_type": "FLT_0D",
  "documentation": "Fabrication cost per unit volume of this layer",
  "type": "static",
  "units": "USD/m^3"
}
```

Julia has no struct inheritance, and the generator reads only *your* schema. Your
concrete is a **sibling** of IFEdd's default under the same abstract, not a derivative
of it — the two share a dispatch surface, not a layout. Every field you want must be
in your JSON:

```@example example
using IFEdd

schema_dir = joinpath(pkgdir(IFEdd), "examples", "custom_build_layer",
                      "data_dictionary", "data_structures_extra")

IFEdd.@bake_dd MyDD = (
    schema_dir    = schema_dir,
    slot_bindings = Dict(:AbstractIFEBuildLayer => :my_layer),
)

payload(T) = sort([f for f in fieldnames(T)
                   if !startswith(string(f), "_") && !endswith(string(f), "_σ")])

default_fields = payload(IFEdd.build__layer{Float64})
custom_fields = payload(parentmodule(MyDD).my_layer{Float64})

(kept  = intersect(default_fields, custom_fields),
 added = setdiff(custom_fields, default_fields),
 lost  = setdiff(default_fields, custom_fields))
```

`lost` is empty *only* because the schema was copied whole. Drop a line from the JSON
and that field moves to `lost` — silently, since nothing requires a substituted type
to resemble the default. Dispatch still succeeds; the failure surfaces later, when
some caller reaches for the missing field.

There is no `extend` directive. Copying is the supported path: open IFEdd's
`data_dictionary/data_structures_extra/build.json`, lift the `build.layer` entries,
rewrite the path prefix to your concrete's name, and add what you need.

## What you do not copy

```@example example
dd = MyDD()
(eltype(dd.build.layer),                                  # your layer
 fieldnames(typeof(dd.build)),                            # parent rebuilt around it
 fieldtype(IFEdd.build{Float64}, :layer))                 # IFEdd's own: untouched
```

The parent `build` was regenerated from IFEdd's schema with only the element type
swapped, so `time`, `code` and `ids_properties` came along for free. Housekeeping
fields (`_name`, `_filled`, `_parent`, …) and the `_σ` uncertainty companions are
emitted automatically. Slots you did not bind keep their defaults.

The rule of thumb: **outward from the substitution point is automatic, inward is
yours.**

## Nested structures come with you

The copied schema carried its nested `_supertype` marker along, so `outline` is
re-emitted under your own name rather than pointing at IFEdd's:

```@example example
outline_type = fieldtype(parentmodule(MyDD).my_layer{Float64}, :outline)

(outline_type,
 outline_type <: IFEdd.AbstractIFEBuildLayerOutline,
 outline_type === IFEdd.build__layer___outline{Float64})
```

Same fields, same abstract, different identity. A method written against
`::IFEdd.AbstractIFEBuildLayerOutline` accepts it; one written against the concrete
`::IFEdd.build__layer___outline` does not — the concrete-versus-abstract signature
question again, one level down.
