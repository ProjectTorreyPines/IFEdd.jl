[![CI](https://github.com/ProjectTorreyPines/IFEdd.jl/actions/workflows/runtests.yml/badge.svg)](https://github.com/ProjectTorreyPines/IFEdd.jl/actions/workflows/runtests.yml)
[![codecov](https://codecov.io/github/ProjectTorreyPines/IFEdd.jl/graph/badge.svg)](https://codecov.io/github/ProjectTorreyPines/IFEdd.jl)

# IFEdd.jl

`IFEdd.jl` is the Inertial Fusion Energy (IFE) data dictionary, a satellite of [`IMASdd.jl`](https://github.com/ProjectTorreyPines/IMASdd.jl). It contributes the IDSs that IFE workflows need without modifying or duplicating any IMASdd source.

Higher-level orchestration for IFE — actors, initialization, study cases — lives in the companion package [`IFE.jl`](https://github.com/ProjectTorreyPines/IFE.jl).

## Data schema

IFE devices do not map onto the magnetic-confinement ontology that IMAS was written for: there is no equilibrium to solve, and the machine is described by a driver, a target, and a chamber rather than by coils and a plasma boundary. `IFEdd.jl` adds the IDSs that describe those (`summary`, `build`, `driver`) as JSON schemas alongside IMASdd's own, and generates the corresponding Julia types from them. Schema metadata is registered into IMASdd's shared registry when the package loads, so IFE quantities are introspectable through exactly the same API as any IMAS quantity.

## A sibling data dictionary

`IMASdd.dd` is one concrete realization of the abstract `IMASdd.DD` container, not the only possible one. `IFEdd.dd` is a second: it embeds the IFE-specific IDSs together with the IMASdd IDSs that carry over unchanged (`core_profiles`, `costing`, `balance_of_plant`, …), and subtypes `IMASdd.DD` directly rather than deriving from `IMASdd.dd`.

The practical consequence is that any routine written against the abstract type — throughout IMASdd, IMAS, and FUSE — accepts an IFE data dictionary without modification, while IFE-specific physics dispatches on the IFE types.

## Customizable containers

A project with its own IFE variant rarely wants IFEdd's defaults verbatim. `IFEdd.generate_user_dd` bakes a customized container for a downstream package, substituting user-supplied concrete IDSs for IFEdd's defaults at any depth of the tree.

Substituted types keep their place in the abstract hierarchy, so code written against the abstracts continues to dispatch correctly, and the generated package carries a provenance manifest that lets CI detect drift from the schemas it was baked against.

## Online documentation

For more details, see the [online documentation](https://projecttorreypines.github.io/IFEdd.jl/dev).

![Docs](https://github.com/ProjectTorreyPines/IFEdd.jl/actions/workflows/make_docs.yml/badge.svg)
