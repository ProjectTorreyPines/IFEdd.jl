# Package recipe

End-to-end walkthrough for a package that ships its own IFE data dictionary. The
generated source ends up under version control alongside your hand-written code, and
a documented `Pkg.build` step regenerates it after a schema change.

## 1. Package skeleton

```bash
julia -e 'using Pkg; Pkg.generate("MyPkg")'
cd MyPkg
mkdir -p data_dictionary/data_structures_extra deps
```

```toml
# Project.toml
name = "MyPkg"
uuid = "…"
version = "0.1.0"

[deps]
IFEdd  = "b7ef78e8-7dbb-4c2e-aaed-bb48b048103f"
IMASdd = "c5a45a97-b3f9-491c-b9a7-aa88c3bc0067"

[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test"]
```

## 2. Schema

`data_dictionary/data_structures_extra/my_summary.json`:

```json
{
 "my_summary": {
  "_supertype": "AbstractIFESummary",
  "documentation": "Custom IFE summary for the XYZ design point"
 },
 "my_summary.yield": {
  "data_type": "FLT_0D",
  "documentation": "Fusion yield per shot",
  "type": "static",
  "units": "MJ"
 },
 "my_summary.gain": {
  "data_type": "FLT_0D",
  "documentation": "Target gain G = E_fusion / E_laser",
  "type": "static",
  "units": "-"
 }
}
```

This is a stock IMAS schema file. `_supertype` is the only key IFEdd adds — without
it the generator would fall back to deriving a supertype from shape alone
(`STRUCT_ARRAY` → `IDSvectorStaticElement`, and so on), which cannot express *which*
IFE structure a type is. It is required on the root entry, its value must name an
abstract in [the lattice](../concepts/abstracts.md), and it may also appear on nested
`STRUCTURE` / `STRUCT_ARRAY` entries — see [Substituting sub-IDSs](substitution.md).
It is rejected on leaf scalars and on `time`.

!!! warning "Write schemas in your package, never in IFEdd's"
    `schema_extra_dir` points at *your* `data_dictionary/data_structures_extra/`.
    IFEdd's own directory of the same name is read by the generator — it needs the
    default schemas to regenerate parent IDSs — but it must not be edited: changes
    there alter IFEdd for every package that depends on it, and are lost on upgrade.
    `ifedd_default_schema_dir` exists only for sysimages and relocated installs where
    `pkgdir(IFEdd)` returns `nothing`.

## 3. `deps/build.jl`

```julia
using IFEdd

const PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))

IFEdd.generate_user_dd(
    output_dir       = joinpath(PROJECT_ROOT, "src"),
    target_module    = :MyPkg,
    schema_extra_dir = joinpath(PROJECT_ROOT, "data_dictionary",
                                "data_structures_extra"),
    slot_bindings    = Dict(:summary => :my_summary),
    verbose          = true,
)
```

## 4. `src/MyPkg.jl`

```julia
module MyPkg

using IMASdd
using IFEdd

include("MyPkg_idstypes.jl")
include("MyPkg_dd.jl")

end
```

## 5. Build

```bash
julia --project -e 'using Pkg; Pkg.build("MyPkg")'
```

Three files appear under `src/`:

| File | Contents |
|---|---|
| `MyPkg_idstypes.jl` | your concrete IDS structs, plus any parent IDSs that had to be regenerated |
| `MyPkg_dd.jl` | `MyPkg.dd{T} <: IFEdd.AbstractIFEDD{T}`, its constructor, and `__init__` |
| `MyPkg_dd_manifest.json` | provenance hashes and resolved bindings |

Commit all three. See
[Source of truth vs. generated artifacts](overview.md#Source-of-truth-vs.-generated-artifacts).

## 6. Use

```julia
using MyPkg, IFEdd, IMASdd

dd = MyPkg.dd()

dd isa IFEdd.AbstractIFEDD{Float64}              # true
dd.summary isa IFEdd.AbstractIFESummary{Float64} # true
dd.summary.yield = 12.0
dd.build isa IFEdd.build{Float64}                # true — unsubstituted slot
```

Anything written against `IFEdd.AbstractIFEDD`, `IMASdd.DD`, or the per-IDS IFE
abstracts accepts `MyPkg.dd` without modification.

## 7. Freshness check in CI

Assert that the committed artifacts still match what the generator produces:

```julia
using Test, IFEdd

mktempdir() do tmp
    IFEdd.generate_user_dd(
        output_dir       = tmp,
        target_module    = :MyPkg,
        schema_extra_dir = joinpath(pkgdir(MyPkg), "data_dictionary",
                                    "data_structures_extra"),
        slot_bindings    = Dict(:summary => :my_summary),
    )
    for f in ("MyPkg_idstypes.jl", "MyPkg_dd.jl")
        @test read(joinpath(tmp, f), String) ==
              read(joinpath(pkgdir(MyPkg), "src", f), String)
    end
end
```

Emission is deterministic — sorted keys, stable ordering — so byte equality is a
legitimate assertion and not a flaky one. This test fails exactly when someone edits
a schema without rebuilding, or when an IFEdd upgrade changes the emitted shape.
