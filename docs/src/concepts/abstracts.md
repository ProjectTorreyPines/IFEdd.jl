# Abstract type lattice

Every IFE structure — at every depth of the tree, not just the top-level slots — has
an abstract supertype. This is what makes the container customizable: a downstream
package substitutes its own concrete type into a slot, and code that dispatches on
the abstract keeps working.

## What `IFEdd.dd()` gives you

Below is the whole container. The IFE-owned slots are expanded down to every node
that has an abstract — **those nodes, and only those, are the substitution points**.
The IMASdd slots stop at the top: they are ordinary IMAS IDSs, fixed concrete types
with no abstract to bind.

```
IFEdd.dd{T}                                <: AbstractIFEDD  <: IMASdd.DD{T}
│
├── summary                                <: AbstractIFESummary              {IDStop}
│   ├── target                             <: AbstractIFESummaryTarget        {IDS}
│   ├── code                               <: AbstractIDSCode                 {IDS, shared}
│   │   └── library[]                      <: AbstractIDSCodeLibrary          {Vec, shared}
│   └── ids_properties                     <: AbstractIDSProperties           {IDS, shared}
│       ├── plugins                        <: AbstractIDSPropertiesPlugins    {IDS, shared}
│       └── provenance                     <: AbstractIDSPropertiesProvenance {IDS, shared}
│
├── build                                  <: AbstractIFEBuild                {IDStop}
│   ├── layer[]                            <: AbstractIFEBuildLayer           {Vec}
│   │   └── outline                        <: AbstractIFEBuildLayerOutline    {IDS}
│   ├── code                               <: AbstractIDSCode                 {IDS, shared}
│   │   └── library[]                      <: AbstractIDSCodeLibrary          {Vec, shared}
│   └── ids_properties                     <: AbstractIDSProperties           {IDS, shared}
│       ├── plugins                        <: AbstractIDSPropertiesPlugins    {IDS, shared}
│       └── provenance                     <: AbstractIDSPropertiesProvenance {IDS, shared}
│
├── driver                                 <: AbstractIFEDriver               {IDStop}
│   ├── beam[]                             <: AbstractIFEDriverBeam           {Vec}
│   │   └── efficiency                     <: AbstractIFEDriverBeamEfficiency {IDS}
│   ├── code                               <: AbstractIDSCode                 {IDS, shared}
│   │   └── library[]                      <: AbstractIDSCodeLibrary          {Vec, shared}
│   └── ids_properties                     <: AbstractIDSProperties           {IDS, shared}
│       ├── plugins                        <: AbstractIDSPropertiesPlugins    {IDS, shared}
│       └── provenance                     <: AbstractIDSPropertiesProvenance {IDS, shared}
│
├── balance_of_plant       :: IMASdd.balance_of_plant   ─┐
├── blanket                :: IMASdd.blanket             │
├── core_profiles          :: IMASdd.core_profiles       │  IMAS IDSs, carried over
├── core_sources           :: IMASdd.core_sources        │  unchanged. Concrete, and
├── costing                :: IMASdd.costing             │  not substitutable.
├── neutronics             :: IMASdd.neutronics          │
├── pellets                :: IMASdd.pellets             │
├── requirements           :: IMASdd.requirements       ─┘
│
└── global_time            :: Float64

how the node is embedded:  {IDStop} top-level IDS slot
                           {IDS}    single struct field
                           {Vec}    IDSvector element type
plus:                      {shared} this abstract is reused at several
                                    hosts — see below
```

Leaf data fields (`summary.target.gain`, `build.time`, …) are omitted — they are
plain numbers and arrays, not types you can swap. [Data schema](schema.md) lists
them.

The 13 abstracts are all leaves directly under an IMASdd primitive; none subtypes
another IFEdd abstract. Grouping the tree above by that primitive: `IMASdd.IDStop`
holds the three top-level slots, `IMASdd.IDSvectorStaticElement` the three `{Vec}`
element types, and `IMASdd.IDS` the remaining seven.

## Shared abstracts

`AbstractIFE*` abstracts describe structures unique to the IFE ontology, and each
sits at exactly one place in the tree: `AbstractIFEBuildLayer` is `build.layer[]`, and
nothing else.

`AbstractIDS*` abstracts describe the substructures *every* IDS has — `code`,
`ids_properties` and their children. Those appear once per host. Struct names follow
the path, so each host has its own concrete type, but a single abstract covers all of
them:

```
summary.code  ::  summary__code  ─┐
build.code    ::  build__code     ├─  all three  <: AbstractIDSCode
driver.code   ::  driver__code   ─┘
```

That is what `{shared}` marks, and it cuts both ways:

- **Dispatch gets cheaper.** One method on `::AbstractIDSCode` covers every host —
  see [Dispatching on the lattice](#Dispatching-on-the-lattice) below. Without the
  shared abstract you would write three methods, or widen to `IMASdd.IDS` and lose
  all type safety.
- **Binding gets stricter.** A bare key cannot say *which* host you mean, so it is
  rejected with `:shared_abstract_needs_path`; you name the host instead. See
  [Substituting sub-IDSs](../customizing/substitution.md#Abstract-name-plus-host).

```julia
Dict(:AbstractIFEBuildLayer => :my_layer)               # one site — unambiguous
Dict(:AbstractIDSCode       => :my_code)                # error: which host?
Dict(:AbstractIDSCode => Dict(:summary => :my_code))    # host named
```

The naming distinguishes the two families deliberately: `AbstractIDS*` carries no `IFE` infix
because it describes IDSs in general. If IMASdd later publishes its own equivalents,
IFEdd's declarations collapse to `const` aliases without breaking downstream dispatch.

The authoritative machine-readable copy is `data_dictionary/abstracts.json`, derived
from the schemas and verified by the test suite. `generate_user_dd` validates
user-supplied abstract names against it.

## Dispatching on the lattice

Write signatures against the abstract, not the concrete:

```@example lattice
using IFEdd

# Covers IFEdd.build__layer AND any user-substituted layer type
layer_cost(layer::IFEdd.AbstractIFEBuildLayer, rate_per_m3::Real) = layer.volume * rate_per_m3

# One method for summary.code, build.code and driver.code alike
audit_software(code::IFEdd.AbstractIDSCode) = code.name

dd = IFEdd.dd()
dd.summary.code.name = "IFE.jl"
dd.driver.code.name = "IFEdd.jl"

(audit_software(dd.summary.code), audit_software(dd.driver.code))
```

Without the shared abstracts, `audit_software` would need three methods, one per
`summary__code` / `build__code` / `driver__code`, or would have to widen to
`IMASdd.IDS` and lose all type safety.

## The contract for a custom concrete

A type substituted into a slot must:

1. subtype the corresponding abstract, parameterized identically —
   `my_layer{T} <: IFEdd.AbstractIFEBuildLayer{T}`;
2. carry the standard housekeeping fields (`_aux`, `_name`, `_filled`, `_frozen`,
   `_threads_lock`, `_in_expression`, `_parent`) in the order the generator produces.

[`IFEdd.generate_user_dd`](@ref) satisfies both automatically — it introspects the
field order from the corresponding IFEdd default rather than hard-coding it. Writing
such a type by hand is possible but not recommended.
