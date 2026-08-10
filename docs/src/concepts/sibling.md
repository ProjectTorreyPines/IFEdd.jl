# A sibling data dictionary

`IMASdd.dd` is one concrete realization of the abstract `IMASdd.DD` container, not the
only possible one. `IFEdd.dd` is a second.

```
IMASdd.DD{T}                        (abstract)
 ├── IMASdd.dd{T}                   (concrete — the tokamak container)
 └── IFEdd.AbstractIFEDD{T}         (abstract — any IFE container)
      ├── IFEdd.dd{T}               (concrete — the IFE container)
      └── MyPkg.dd{T}               (concrete — a customized variant)
```

`IFEdd.dd` descends from `IMASdd.DD`, not from `IMASdd.dd`. It is a sibling of the
tokamak container, not a descendant — Julia has no concrete-type inheritance, and in
any case the two hold different slots (`IFEdd.dd` has `driver`, no `equilibrium`).

`AbstractIFEDD` is the intermediate rung: every IFE container subtypes it, including
the customized ones from [`generate_user_dd`](../customizing/overview.md).

## Why sibling rather than subtype

Julia has no concrete-type inheritance: a struct cannot subtype another struct. Even
setting that aside, the two containers hold different slots — `IFEdd.dd` has
`driver` and no `equilibrium` — so deriving one from the other would misdescribe the
data. The abstract type is where the shared contract lives.

The practical consequence is that any routine written against `IMASdd.DD` — anywhere
in IMASdd, IMAS or FUSE — accepts an IFE data dictionary without modification, while
IFE-specific physics dispatches on the IFE types:

```@example sibling
using IFEdd
import IMASdd

# One method, both containers
elapsed(dd::IMASdd.DD) = dd.global_time

(elapsed(IFEdd.dd()), elapsed(IMASdd.dd()))
```

## Which one to write in a signature

Never `::IFEdd.dd`. Constraining to the concrete buys nothing and locks out every
customized container from [Customizing the container](../customizing/overview.md).

Between the two abstracts, pick by what the function actually touches:

| Signature | Accepts | Use when |
|---|---|---|
| `::IMASdd.DD` | any data dictionary, IFE or tokamak | you only touch shared slots (`costing`, `core_profiles`, `global_time`) |
| `::IFEdd.AbstractIFEDD` | any IFE container, and only those | you touch `driver`, `build` or `summary` |

The narrower one is not pedantry: `IMASdd.dd` has no `driver` field, so a function
that reaches for one and is typed `::IMASdd.DD` fails deep inside its body instead of
at the call site.

```@example sibling
(IFEdd.dd{Float64}  <: IFEdd.AbstractIFEDD{Float64},
 IFEdd.AbstractIFEDD{Float64} <: IMASdd.DD{Float64},
 IMASdd.dd{Float64} <: IFEdd.AbstractIFEDD)      # the tokamak container: excluded
```

## What comes for free

Because `IFEdd.dd` sits under `IMASdd.DD` and its IDSs sit under `IMASdd.IDStop` /
`IMASdd.IDS` / `IMASdd.IDSvectorStaticElement`, IMASdd's machinery applies without
any overrides on the IFEdd side:

- field-presence tracking (`ismissing`, `isfrozen`, the `FilledFields` companions)
- parent links and path printing
- expressions and time-dependent access
- `deepcopy`, `freeze`, `fill!`
- JSON and HDF5 serialization

## Serialization round-trips

`imas2hdf` records the concrete type of the container it wrote, and `hdf2imas`
reads it back:

```@example sibling
dd = IFEdd.dd()
dd.summary.target.gain = 85.0

path = joinpath(mktempdir(), "shot.h5")
IMASdd.imas2hdf(dd, path)

back = IMASdd.hdf2imas(path)        # reconstructs an IFEdd.dd, not an IMASdd.dd

(typeof(back), back.summary.target.gain)
```

The satellite package defining the container must be loaded for this to resolve —
`using IFEdd` before the read. Files written before this metadata existed still load,
falling back to `IMASdd.dd`.

!!! note
    Type-aware reconstruction requires `IMASdd` ≥ 8.6.2, which IFEdd's `[compat]`
    bound enforces.
