# Re-bake MyIFEProject's customized dd by re-running IFEdd.generate_user_dd
# against the current IFEdd abstracts.json + the package's own user
# schemas. Invoked by `Pkg.build("MyIFEProject")`.
#
# This file is the canonical template that downstream user packages
# should copy into their own `deps/build.jl`. See
# the package README for narrative.

using IFEdd

const PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))
const SCHEMA_DIR   = joinpath(PROJECT_ROOT, "data_dictionary",
                              "data_structures_extra")
const OUTPUT_DIR   = joinpath(PROJECT_ROOT, "src")

@info "MyIFEProject build" PROJECT_ROOT SCHEMA_DIR OUTPUT_DIR

result = IFEdd.generate_user_dd(
    output_dir       = OUTPUT_DIR,
    target_module    = :MyIFEProject,
    schema_extra_dir = SCHEMA_DIR,
    # Explicit binding: the JSON-implied path would also work since
    # there's only one user summary concrete, but explicit is clearer.
    slot_bindings    = Dict(:summary => :my_summary),
    verbose          = true,
)

@info "MyIFEProject build complete" idstypes=result.idstypes_file dd=result.dd_file manifest=result.manifest_file
