# Quick bake

[`IFEdd.@bake_dd`](@ref) collapses the whole [package recipe](package.md) into one
expression. It is the right tool for REPL exploration, one-file analysis scripts and
test fixtures.

## Write a schema

One JSON file per custom IDS, in a directory of your choosing. The top-level entry
declares which abstract the type plugs into:

```@example bake
schema_dir = mkpath(joinpath(mktempdir(), "data_structures_extra"))

write(joinpath(schema_dir, "my_summary.json"), """
{
 "my_summary": {
  "_supertype": "AbstractIFESummary",
  "documentation": "Custom IFE summary for the XYZ design point"
 },
 "my_summary.gain": {
  "data_type": "FLT_0D",
  "documentation": "Target gain G = E_fusion / E_laser",
  "type": "static",
  "units": "-"
 },
 "my_summary.yield": {
  "data_type": "FLT_0D",
  "documentation": "Fusion yield per shot",
  "type": "static",
  "units": "MJ"
 }
}
""")
nothing # hide
```

The format is IMASdd's. Nested paths (`my_summary.beam.energy`) emit nested struct
types (`my_summary__beam{T}`) following the usual naming convention.

Naming your concrete `summary`, `build` or `driver` is rejected — it would shadow an
IFEdd default.

## Bake it

```@example bake
using IFEdd

IFEdd.@bake_dd dd_mine = (
    schema_dir    = schema_dir,
    slot_bindings = Dict(:summary => :my_summary),
)

dd_mine
```

```@example bake
dd = dd_mine()
dd.summary.yield = 12.0

(dd.summary isa IFEdd.AbstractIFESummary{Float64},  # your concrete, via the abstract
 dd.summary.yield,
 typeof(dd.build))                                  # untouched slot keeps the default
```

`dd_mine` is bound to the generated `dd{T}` type, living in a hidden module that the
macro creates. Everything else about it is an ordinary `IFEdd.AbstractIFEDD`.

`slot_bindings` may be omitted when exactly one user schema declares a given
`_supertype` — the binding is then inferred. Passing it explicitly is clearer once
more than one custom type is in play, and it is required for the substitution forms
described in [Substituting sub-IDSs](substitution.md).

## Persisting the generated source

Pass `output_dir` and the emitted files are written there instead of a temporary
directory. That makes the macro usable inside a package module:

```julia
module MyPkg
    using IFEdd
    IFEdd.@bake_dd Custom = (
        schema_dir    = joinpath(@__DIR__, "schemas"),
        output_dir    = joinpath(@__DIR__, "gen"),
        slot_bindings = Dict(:summary => :my_summary),
    )
end

using MyPkg
dd = MyPkg.Custom()
```

For a package that other people contribute to, prefer the explicit
[package recipe](package.md): it puts the boundary between hand-written and generated
source in the file layout, where a reviewer can see it.

## Caching

Bakes without an `output_dir` are cached by manifest hash for the session. Re-running
an identical `@bake_dd` returns the **same** concrete type, so method specializations
compiled against it stay valid. A different left-hand-side name yields a different
type, deliberately — two names should never be silently interchangeable.

## World-age caveat

`@bake_dd` expands to a `let` block ending in a `global` assignment, so the new type
is not visible to the rest of the *same* top-level expression:

```julia
# Fails with a world-age error
begin
    IFEdd.@bake_dd dd_mine = (schema_dir = "…",)
    dd = dd_mine()
end

# Fine — separate statements
IFEdd.@bake_dd dd_mine = (schema_dir = "…",)
dd = dd_mine()
```

At the REPL each prompt is its own world age, so the next line works. In a script,
either split the statements or call `Base.invokelatest(dd_mine)`.

## Provenance

```@example bake
IFEdd.bake_manifest(dd_mine)["slot_bindings"]["summary"]
```

```@example bake
basename.(values(IFEdd.bake_source(dd_mine)))
```

The files behind an ephemeral bake live in a temporary directory that persists for the
session — handy for reading the emitted code when something does not look right.
