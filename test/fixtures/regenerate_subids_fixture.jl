# Regenerate the in-tree MyIFEProject_subids fixture's generated files.
# Run from the IFEdd repo root:
#
#     julia --project test/fixtures/regenerate_subids_fixture.jl
#
# Commit the diff in `test/fixtures/MyIFEProject_subids/src/` afterwards.
# The fixture freshness test (`test/test_subids_fixture.jl`)
# enforces that committed files match the live generator output.

using IFEdd

const FIXTURE_ROOT = joinpath(@__DIR__, "MyIFEProject_subids")
const SCHEMA_DIR   = joinpath(FIXTURE_ROOT, "data_dictionary",
                              "data_structures_extra")
const OUTPUT_DIR   = joinpath(FIXTURE_ROOT, "src")

@info "Regenerating sub-IDS fixture" FIXTURE_ROOT SCHEMA_DIR OUTPUT_DIR

result = IFEdd.generate_user_dd(
    output_dir       = OUTPUT_DIR,
    target_module    = :MyIFEProject_subids,
    schema_extra_dir = SCHEMA_DIR,
    slot_bindings    = Dict(
        :AbstractIFEBuildLayer           => :my_layer,
        :AbstractIFEDriverBeamEfficiency => :my_efficiency,
    ),
    verbose          = true,
)

@info "Regenerated" idstypes=basename(result.idstypes_file) dd=basename(result.dd_file) manifest=basename(result.manifest_file)
