# Data schema

IFE devices do not map onto the magnetic-confinement ontology that IMAS was written
for. There is no equilibrium to solve, and the machine is described by a driver, a
target and a chamber rather than by coils and a plasma boundary. `IFEdd.jl` adds the
IDSs that describe those, as JSON schemas alongside IMASdd's own, and generates the
corresponding Julia types from them.

Schema metadata is registered into IMASdd's shared registry when the package loads,
so IFE quantities are introspectable through exactly the same API as any IMAS
quantity — `IMASdd.info`, `IMASdd.units`, `IMASdd.coordinates` and path printing all
work on them.

## The container

`IFEdd.dd{T}` embeds eleven top-level slots. Three are IFE-owned; the other eight are
IMASdd IDSs that carry over unchanged.

| Slot | Type | Owner |
|---|---|---|
| `summary` | `IFEdd.summary{T}` | IFEdd |
| `build` | `IFEdd.build{T}` | IFEdd |
| `driver` | `IFEdd.driver{T}` | IFEdd |
| `balance_of_plant` | `IMASdd.balance_of_plant{T}` | IMASdd |
| `blanket` | `IMASdd.blanket{T}` | IMASdd |
| `core_profiles` | `IMASdd.core_profiles{T}` | IMASdd |
| `core_sources` | `IMASdd.core_sources{T}` | IMASdd |
| `costing` | `IMASdd.costing{T}` | IMASdd |
| `neutronics` | `IMASdd.neutronics{T}` | IMASdd |
| `pellets` | `IMASdd.pellets{T}` | IMASdd |
| `requirements` | `IMASdd.requirements{T}` | IMASdd |

Every IFE-owned IDS also carries the standard `ids_properties` and `code`
substructures, so provenance and software attribution are recorded the same way as in
any IMAS IDS.

## `summary` — target implosion physics

`summary.target` collects the scalar figures of merit of a single shot.

| Field | Units | Meaning |
|---|---|---|
| `gain` | – | Target gain ``G = E_\mathrm{fusion} / E_\mathrm{laser}`` |
| `ablation_pressure` | Pa | Ablation pressure at peak laser intensity |
| `areal_density` | kg/m² | Compressed fuel areal density ``\rho R`` |
| `burn_fraction` | – | DT burn fraction ``f_b = \rho R / (\rho R + 6.67\,\mathrm{g/cm^2})`` |
| `compressed_radius` | m | Outer radius of the compressed fuel sphere |
| `convergence_ratio` | – | Radial convergence ratio ``R_\mathrm{initial} / R_\mathrm{compressed}`` |
| `ifar` | – | In-flight aspect ratio of the imploding shell ``R/\Delta R`` |
| `implosion_velocity` | m/s | Peak implosion velocity of the shell |
| `intensity` | W/m² | Peak laser intensity on the target surface |
| `temperature_scale` | – | Scaling applied to cold profiles to match target fusion power |

## `build` — chamber radial build

`build.layer` is an array of concentric layers, ordered from the chamber centre
outwards.

| Field | Units | Meaning |
|---|---|---|
| `name` | | Layer name |
| `material` | | Layer material |
| `type` | | Layer type code, following the IMAS `BuildLayerType` convention |
| `start_radius` | m | Inner radius |
| `end_radius` | m | Outer radius |
| `thickness` | m | Radial thickness |
| `area` | m² | Inner surface area (``4\pi r^2`` for spherical geometry) |
| `volume` | m³ | Layer volume |
| `outline.r`, `outline.z` | m | Poloidal cross-section of the layer boundary |

Because the geometry is spherical rather than toroidal, `start_radius` /
`end_radius` are radii from the chamber centre, not major radii.

## `driver` — beam lines

`driver.beam` is an array of beam lines (or ports) of the driver system.

| Field | Units | Meaning |
|---|---|---|
| `identifier` | | Unique identifier for the beam line |
| `name` | | Beam line name |
| `energy` | J | Energy per pulse delivered to the target |
| `wavelength` | m | Laser wavelength |
| `intensity` | W/m² | Peak intensity on target |
| `pulse_length` | s | Duration of a single pulse |
| `power_launched` | W | Time-averaged power launched by the beam line |
| `efficiency.conversion` | – | Electric power → driver power |
| `efficiency.coupling` | – | Fraction of driver energy absorbed by the target |

## Schema source of truth

The schemas live in `data_dictionary/data_structures_extra/` as one JSON file per
IDS, in the same format IMASdd uses. The Julia types in `src/dd_idstypes.jl` and
`src/dd.jl` are generated from them and committed; they are never edited by hand.

To change the schema, edit the JSON and regenerate. The same generator is exposed
publicly as [`IFEdd.generate_user_dd`](@ref) so that downstream packages can bake
their own variant — see [Customizing the container](../customizing/overview.md).
