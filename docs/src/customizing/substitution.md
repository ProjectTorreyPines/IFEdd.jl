# Substituting sub-IDSs

Replacing a top-level slot — `dd.summary` — is the simple case. Substitution works at
any depth of the tree: a custom chamber layer inside `dd.build.layer[:]`, a custom
efficiency structure inside `dd.driver.beam[:].efficiency`.

The mechanism is the same in every case. You bind an abstract to your concrete type,
and the generator regenerates whichever parent IDSs need to change so that your type
appears at the right place — `build` becomes *your* `build`, holding *your* layer.

## Binding forms

`slot_bindings` accepts three key forms, freely mixed in one `Dict`.

### Top-level slot name

```julia
slot_bindings = Dict(:summary => :my_summary)
```

Valid for `:summary`, `:build` and `:driver`. Equivalent to binding the
corresponding `AbstractIFE*` abstract, and it is the form to reach for when
substituting a whole IDS.

### Abstract name

```julia
slot_bindings = Dict(
    :AbstractIFEBuildLayer           => :my_layer,
    :AbstractIFEDriverBeamEfficiency => :my_efficiency,
)
```

Valid for any abstract that has exactly one default concrete — every `AbstractIFE*`
in the lattice. Keys are recognized by lookup against `abstracts.json`, so a typo
raises an error naming the supported set rather than silently doing nothing.

### Abstract name plus host

Shared abstracts (`AbstractIDSCode`, `AbstractIDSProperties`, …) have one default
concrete *per host IDS*, so a bare abstract key is ambiguous and is rejected with
`:shared_abstract_needs_path`. Name the host as well:

```julia
slot_bindings = Dict(
    :AbstractIDSCode => Dict(
        :summary => :my_summary_code,
        :build   => :my_build_code,
        # :driver omitted → driver.code keeps the IFEdd default
    ),
)
```

or, for a single site, the tuple-key shorthand:

```julia
slot_bindings = Dict((:AbstractIDSCode, :summary) => :my_summary_code)
```

Both normalize to the same internal representation.

## Writing the schema

The schema shape must match how the slot is embedded.

For an **`IDSvector` element** — `build.layer[:]` — use the struct-array convention,
with `[:]` in the field paths:

```@example sub
schema_dir = mkpath(joinpath(mktempdir(), "data_structures_extra"))

write(joinpath(schema_dir, "my_layer.json"), """
{
 "my_layer": {
  "_supertype": "AbstractIFEBuildLayer",
  "data_type": "STRUCT_ARRAY",
  "documentation": "Chamber layer with a per-volume cost rate"
 },
 "my_layer[:].name":      { "data_type": "STR_0D", "type": "static", "documentation": "Layer name" },
 "my_layer[:].thickness": { "data_type": "FLT_0D", "type": "static", "units": "m", "documentation": "Radial thickness" },
 "my_layer[:].cost_rate": { "data_type": "FLT_0D", "type": "static", "units": "USD/m^3", "documentation": "Per-volume cost" }
}
""")
nothing # hide
```

For a **directly embedded structure** — `driver.beam[:].efficiency` — use the plain
dotted form instead, without the `[:]`:

```json
{
 "my_efficiency": {
  "_supertype": "AbstractIFEDriverBeamEfficiency",
  "data_type": "STRUCTURE",
  "documentation": "Driver efficiency including a cooling correction"
 },
 "my_efficiency.conversion":         { "data_type": "FLT_0D", "type": "static", "units": "-", "documentation": "Electric to driver" },
 "my_efficiency.coupling":           { "data_type": "FLT_0D", "type": "static", "units": "-", "documentation": "Driver to target" },
 "my_efficiency.cooling_correction": { "data_type": "FLT_0D", "type": "static", "units": "-", "documentation": "Cooling derate" }
}
```

## Baking

```@example sub
using IFEdd

IFEdd.@bake_dd MyDD = (
    schema_dir    = schema_dir,
    slot_bindings = Dict(:AbstractIFEBuildLayer => :my_layer),
)

dd = MyDD()
fieldtype(typeof(dd.build), :layer)
```

`build` was regenerated to hold `my_layer` — and `push!`ing one needs no manual
fixup, because the generator preserves the `IDSvector` naming invariant when it
rewrites the parent.

Generated concretes live alongside the container: with the
[package recipe](package.md) you write `MyPkg.my_layer{Float64}()`, and with
`@bake_dd` they sit in a hidden module reachable via `parentmodule(MyDD)`.

## Substitution is not recursive

Binding a parent abstract does not bind its children. `:AbstractIFEBuildLayer =>
:my_layer` leaves `AbstractIFEBuildLayerOutline` on the IFEdd default; bind it too if
you want both replaced.

What *is* automatic: once both are bound, a nested `_supertype` marker inside your own
schema wires your child concrete into your parent, instead of leaving the parent
pointing at the anonymous nested struct the generator would otherwise emit.

```json
"my_layer[:].outline": {
  "_supertype": "AbstractIFEBuildLayerOutline",
  "data_type": "STRUCTURE",
  "documentation": "Custom outline"
}
```

```julia
slot_bindings = Dict(
    :AbstractIFEBuildLayer        => :my_layer,
    :AbstractIFEBuildLayerOutline => :my_outline,
)
```

Without the marker the nested default is kept — the behaviour is strictly opt-in.

## Marker placement rules

- `_supertype` markers belong on `STRUCTURE` and `STRUCT_ARRAY` entries only. On a
  leaf scalar or on `time` they raise `:bad_marker_placement`.
- The abstract named must exist in `abstracts.json`.
- Abstract names must be valid Julia identifiers. Names outside the `AbstractIFE*` /
  `AbstractIDS*` convention are accepted with a warning.

## What does not change

- `IFEdd.dd()` is untouched. Substitution is per-bake, and several packages with
  different substitutions coexist in one session.
- Slots you do not bind keep their IFEdd or IMASdd defaults, with their original
  module qualification.
- Abstract dispatch keeps working — that is the whole point of the lattice.

```@example sub
(fieldtype(IFEdd.build{Float64}, :layer),   # IFEdd's own container: unchanged
 typeof(dd.summary))                        # unbound slot keeps the default
```
