[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://projecttorreypines.github.io/IFEdd.jl/dev/)
[![CI](https://github.com/ProjectTorreyPines/IFEdd.jl/actions/workflows/runtests.yml/badge.svg)](https://github.com/ProjectTorreyPines/IFEdd.jl/actions/workflows/runtests.yml)
[![Docs](https://github.com/ProjectTorreyPines/IFEdd.jl/actions/workflows/make_docs.yml/badge.svg)](https://github.com/ProjectTorreyPines/IFEdd.jl/actions/workflows/make_docs.yml)
[![codecov](https://codecov.io/github/ProjectTorreyPines/IFEdd.jl/graph/badge.svg)](https://codecov.io/github/ProjectTorreyPines/IFEdd.jl)

# IFEdd.jl

The Inertial Fusion Energy (IFE) data dictionary: a satellite of
[`IMASdd.jl`](https://github.com/ProjectTorreyPines/IMASdd.jl) that adds the IDSs IFE
workflows need, without modifying or duplicating any IMASdd source.

Higher-level orchestration — actors, initialization, study cases — lives in the companion
package [`IFE.jl`](https://github.com/ProjectTorreyPines/IFE.jl).

```julia
using IFEdd

dd = IFEdd.dd()
dd.summary.target.gain = 85.0
```

## What it provides

- **IFE IDSs.** `summary`, `build` and `driver`, written as JSON schemas alongside
  IMASdd's own and generated into Julia types. Their metadata is registered with IMASdd
  on load, so IFE quantities introspect exactly like IMAS ones.

- **A sibling container.** `IFEdd.dd` subtypes `IMASdd.DD` directly rather than deriving
  from `IMASdd.dd`, so any routine written against the abstract type — across IMASdd,
  IMAS and FUSE — accepts an IFE data dictionary unchanged.

- **Customizable containers.** `IFEdd.generate_user_dd` bakes a variant for a downstream
  package, substituting user-supplied IDSs at any depth while keeping the abstract
  hierarchy intact.

## Documentation

See the [online documentation](https://projecttorreypines.github.io/IFEdd.jl/dev/).
