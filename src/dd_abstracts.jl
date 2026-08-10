# Abstract type lattice for IFEdd's top-level local IDS.
#
# Each top-level IFE-owned IDS has an abstract supertype here. Downstream
# packages bake a user-customized `dd{T}` by emitting a concrete IDS that
# subtypes one of these abstracts; their `dd{T}` then embeds the user
# concrete in place of IFEdd's default `summary` / `build` / `driver`.
#
# Single source of truth for the lattice is `data_dictionary/abstracts.json`
# (verified by `test/test_abstracts.jl`).

"""
    AbstractIFEDD{T} <: IMASdd.DD{T}

Supertype for any IFE top-level container. IFEdd's own `dd{T}` is the
default concrete; every container baked by [`IFEdd.generate_user_dd`](@ref)
subtypes it too.

Sits between `IMASdd.DD` and the concretes so that IFE code can accept any
IFE container without naming one: `f(dd::IFEdd.AbstractIFEDD)` covers
`IFEdd.dd` and every customized variant, while still excluding
`IMASdd.dd` — which has no `driver` or `build` to operate on.

Unlike the per-IDS abstracts below, this one is declared here rather than
derived from a `_supertype` marker: the container has no JSON schema. It is
therefore absent from `abstracts.json` and cannot appear in `slot_bindings`
— substituting the container into itself is not meaningful.
"""
abstract type AbstractIFEDD{T} <: IMASdd.DD{T} end

"""
    AbstractIFESummary{T} <: IMASdd.IDStop{T}

Supertype for any concrete IFE *summary* IDS. IFEdd's own
`summary{T}` is the default concrete. User packages
substituting a custom summary IDS into `dd.summary` MUST declare their
concrete type as `<: IFEdd.AbstractIFESummary{T}` so that dispatch
written for `::IFEdd.AbstractIFESummary` covers it.

The user concrete must additionally carry the standard housekeeping
fields (`_aux`, `_name`, `_filled`, `_frozen`, `_threads_lock`,
`_in_expression`, `_parent`) in the order produced by the default
generator. The order is introspected from `fieldnames(IFEdd.summary)`
minus payload fields by [`IFEdd.generate_user_dd`](@ref).
"""
abstract type AbstractIFESummary{T} <: IMASdd.IDStop{T} end

"""
    AbstractIFEBuild{T} <: IMASdd.IDStop{T}

Supertype for any concrete IFE *build* IDS. See [`AbstractIFESummary`](@ref)
for the per-instance contract. IFEdd's default concrete is `build{T}`,
which carries `layer::IMASdd.IDSvector{build__layer{T}}` and time-series
fields.
"""
abstract type AbstractIFEBuild{T} <: IMASdd.IDStop{T} end

"""
    AbstractIFEDriver{T} <: IMASdd.IDStop{T}

Supertype for any concrete IFE *driver* IDS. See [`AbstractIFESummary`](@ref)
for the per-instance contract. IFEdd's default concrete is `driver{T}`,
which carries `beam::IMASdd.IDSvector{driver__beam{T}}` and time-series
fields.
"""
abstract type AbstractIFEDriver{T} <: IMASdd.IDStop{T} end

"""
    AbstractIFESummaryTarget{T} <: IMASdd.IDS{T}

Nested abstract for the *target* sub-structure of any IFE summary IDS.
IFEdd's default concrete is `summary__target{T}`, carrying target
implosion physics scalars (gain, yield, ablation_pressure, etc.).

Enables dispatch on `::AbstractIFESummaryTarget`
for any user-baked summary whose `target` sub-IDS subtypes this. The
container `summary{T}` still embeds the IFEdd concrete `summary__target{T}`
by default; users substitute sub-IDS through `slot_bindings`.
"""
abstract type AbstractIFESummaryTarget{T} <: IMASdd.IDS{T} end

"""
    AbstractIFEBuildLayer{T} <: IMASdd.IDSvectorStaticElement{T}

Element-type abstract for `build.layer[:]` — each concentric layer
of the IFE chamber radial build. IFEdd's default concrete is
`build__layer{T}`, carrying `name`, `material`, `thickness`,
`volume`, etc. Parent is `IDSvectorStaticElement` because layers
live inside an `IDSvector{build__layer{T}}` array.

A method written as `f(layer::IFEdd.AbstractIFEBuildLayer)` covers any
user-defined layer concrete that subtypes this.
"""
abstract type AbstractIFEBuildLayer{T} <: IMASdd.IDSvectorStaticElement{T} end

"""
    AbstractIFEBuildLayerOutline{T} <: IMASdd.IDS{T}

Nested abstract for the *outline* sub-structure of a build layer —
the 2-D poloidal cross-section `(r, z)` curve bounding the layer.
IFEdd's default concrete is `build__layer___outline{T}` (note the
`___` separator marking it as a sub-structure of an `IDSvector`
element).
"""
abstract type AbstractIFEBuildLayerOutline{T} <: IMASdd.IDS{T} end

"""
    AbstractIFEDriverBeam{T} <: IMASdd.IDSvectorStaticElement{T}

Element-type abstract for `driver.beam[:]` — each beam line of the
IFE driver system. IFEdd's default concrete is `driver__beam{T}`,
carrying `identifier`, `energy`, `wavelength`, `intensity`,
`power_launched`, plus a nested `efficiency` substructure.
"""
abstract type AbstractIFEDriverBeam{T} <: IMASdd.IDSvectorStaticElement{T} end

"""
    AbstractIFEDriverBeamEfficiency{T} <: IMASdd.IDS{T}

Nested abstract for the *efficiency* sub-structure of a driver beam,
carrying `conversion` (wall-plug → laser) and `coupling`
(driver → target) fractions. IFEdd's default concrete is
`driver__beam___efficiency{T}`.
"""
abstract type AbstractIFEDriverBeamEfficiency{T} <: IMASdd.IDS{T} end

# ============================================================================
# Shared cross-IDS abstracts
# ----------------------------------------------------------------------------
# Naming: `AbstractIDS<Substructure>` (no IFE infix). These cover
# substructures common to ALL IDS roots (summary, build, driver, AND any
# future IFE IDS, AND — by convention — any IMASdd IDS that adopts the
# same pattern). When IMASdd ships its own `AbstractIDS<*>`, this file
# converts to `const AbstractIDSCode = IMASdd.AbstractIDSCode` etc.
# ============================================================================

"""
    AbstractIDSCode{T} <: IMASdd.IDS{T}

Cross-IDS abstract for `<root>.code` substructures (carries
`commit`, `description`, `name`, `library`, `output_flag`, etc.).
IFEdd's default concretes per host: `summary__code`, `build__code`,
`driver__code`.

Dispatch over this abstract covers any future user concrete that
subtypes `AbstractIDSCode` AND IFEdd's three defaults uniformly.
"""
abstract type AbstractIDSCode{T} <: IMASdd.IDS{T} end

"""
    AbstractIDSCodeLibrary{T} <: IMASdd.IDSvectorStaticElement{T}

Cross-IDS abstract for `<root>.code.library[:]` array elements.
IFEdd's default concretes per host: `summary__code__library`,
`build__code__library`, `driver__code__library`.
"""
abstract type AbstractIDSCodeLibrary{T} <: IMASdd.IDSvectorStaticElement{T} end

"""
    AbstractIDSProperties{T} <: IMASdd.IDS{T}

Cross-IDS abstract for `<root>.ids_properties` substructures
(carries `comment`, `creation_date`, `homogeneous_time`, nested
`plugins` / `provenance`, etc.). IFEdd's default concretes per host:
`summary__ids_properties`, `build__ids_properties`,
`driver__ids_properties`.
"""
abstract type AbstractIDSProperties{T} <: IMASdd.IDS{T} end

"""
    AbstractIDSPropertiesPlugins{T} <: IMASdd.IDS{T}

Cross-IDS abstract for `<root>.ids_properties.plugins` substructures
(plugin infrastructure metadata, `node` array, infrastructure-get/put
substructures). IFEdd's default concretes per host:
`summary__ids_properties__plugins`, `build__ids_properties__plugins`,
`driver__ids_properties__plugins`.
"""
abstract type AbstractIDSPropertiesPlugins{T} <: IMASdd.IDS{T} end

"""
    AbstractIDSPropertiesProvenance{T} <: IMASdd.IDS{T}

Cross-IDS abstract for `<root>.ids_properties.provenance` substructures
(provenance node list). IFEdd's default concretes per host:
`summary__ids_properties__provenance`, `build__ids_properties__provenance`,
`driver__ids_properties__provenance`.
"""
abstract type AbstractIDSPropertiesProvenance{T} <: IMASdd.IDS{T} end

# Companion-struct prefix for `IMASdd.FilledFields` subtypes that the
# generator emits alongside each IDS. IMASdd does NOT export an equivalent
# constant, so it is owned here.
const FILLED_FIELDS_PREFIX = "FilledFields____"
