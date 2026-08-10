# API Reference

`IFEdd` exports nothing — every name below is written qualified. See
[A sibling data dictionary](concepts/sibling.md) for why.

## Container

```@docs
IFEdd.AbstractIFEDD
IFEdd.dd
```

The IDS types themselves (`IFEdd.summary`, `IFEdd.build`, `IFEdd.driver` and their
substructures) are generated from the JSON schemas and documented per field through
`IMASdd.info`. See [Data schema](concepts/schema.md) for the field listing.

## Abstract types

IFE-specific:

```@docs
IFEdd.AbstractIFESummary
IFEdd.AbstractIFESummaryTarget
IFEdd.AbstractIFEBuild
IFEdd.AbstractIFEBuildLayer
IFEdd.AbstractIFEBuildLayerOutline
IFEdd.AbstractIFEDriver
IFEdd.AbstractIFEDriverBeam
IFEdd.AbstractIFEDriverBeamEfficiency
```

Shared across IDSs:

```@docs
IFEdd.AbstractIDSCode
IFEdd.AbstractIDSCodeLibrary
IFEdd.AbstractIDSProperties
IFEdd.AbstractIDSPropertiesPlugins
IFEdd.AbstractIDSPropertiesProvenance
```

## Generator

```@docs
IFEdd.generate_user_dd
IFEdd.@bake_dd
```

## Provenance

```@docs
IFEdd.bake_manifest
IFEdd.bake_source
```

## Errors

```@docs
IFEdd.GeneratorError
```
