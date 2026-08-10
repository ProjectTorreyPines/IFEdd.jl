#!/usr/bin/env julia
"""
    derive_abstracts.jl — abstracts.json generator

Walks `data_dictionary/data_structures_extra/*.json`, harvests every
`_supertype` marker, validates placement + naming, and writes the
canonical `data_dictionary/abstracts.json` lockfile.

This is the **sole** producer of `abstracts.json`. Hand-edits are
banned (signalled by the `_derived_from` sentinel in the output). CI
re-runs this script and asserts byte-equality
(`test/test_abstracts_derive.jl`).

Run: `julia --project scripts/derive_abstracts.jl`.
"""

using IFEdd

const IFEDD_ROOT = normpath(joinpath(@__DIR__, ".."))
const IFEDD_DD   = joinpath(IFEDD_ROOT, "data_dictionary")
const EXTRAS_DIR = joinpath(IFEDD_DD, "data_structures_extra")
const OUT_PATH   = joinpath(IFEDD_DD, "abstracts.json")

function main()
    @info "deriving abstracts.json" extras=EXTRAS_DIR target=OUT_PATH

    # Walk schemas, build the lattice
    lattice = IFEdd.derive_abstracts(EXTRAS_DIR)
    n_abstracts = length(lattice.abstracts)
    n_defaults  = length(lattice.default_concretes)
    n_schemas   = count(fn -> endswith(fn, ".json"), readdir(EXTRAS_DIR))

    @info "Schemas walked" files=n_schemas abstracts=n_abstracts defaults=n_defaults

    # Serialize via the pinned formatter
    text = IFEdd.format_abstracts_json(lattice.abstracts, lattice.default_concretes)

    # Bootstrap-on-missing: don't raise if abstracts.json is absent;
    # just create it. CI's freshness test will catch unintended drift.
    existed_before = isfile(OUT_PATH)
    if existed_before
        old = read(OUT_PATH, String)
        if old == text
            @info "Lockfile unchanged" path=OUT_PATH
            return nothing
        end
        @info "Lockfile differs — overwriting" path=OUT_PATH old_bytes=length(old) new_bytes=length(text)
    else
        @info "Lockfile being created for the first time" path=OUT_PATH
    end

    IFEdd.atomic_write(OUT_PATH, text)
    @info "Wrote lockfile" path=OUT_PATH bytes=filesize(OUT_PATH)
    return nothing
end

main()
