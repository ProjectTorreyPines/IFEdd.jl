using Documenter, IFEdd

makedocs(;
    modules=[IFEdd],
    sitename="IFEdd",
    authors="Min-Gu Yoo",
    # IFEdd's `dd` / `summary` / `build` / `driver` deliberately shadow IMASdd
    # names and are therefore never exported, so `:exports` would check an
    # empty set. The API reference lists the public surface explicitly.
    checkdocs=:none,
    # Declared rather than sniffed from `git remote`, so the docs build works
    # from a clone that has no remote configured.
    remotes=Dict(
        dirname(@__DIR__) => (Documenter.Remotes.GitHub("ProjectTorreyPines", "IFEdd.jl"), "master")),
    format=Documenter.HTML(;
        analytics="G-65D8V8C8VQ",
        canonical="https://projecttorreypines.github.io/IFEdd.jl",
        edit_link="master",
        size_threshold=nothing,
        size_threshold_warn=nothing),
    pages=[
        "Home" => "index.md",
        "Concepts" => [
            "Data schema" => "concepts/schema.md",
            "A sibling data dictionary" => "concepts/sibling.md",
            "Abstract type lattice" => "concepts/abstracts.md",
        ],
        "Customizing the container" => [
            "Overview" => "customizing/overview.md",
            "Quick bake" => "customizing/bake.md",
            "Package recipe" => "customizing/package.md",
            "Substituting sub-IDSs" => "customizing/substitution.md",
            "Worked example" => "customizing/example.md",
            "Troubleshooting" => "customizing/troubleshooting.md",
        ],
        "API Reference" => "api.md",
    ],
    # Not `warnonly`: the `@example` blocks exist so that a stale example breaks
    # the build rather than shipping wrong code to readers.
)

# Deploy docs
# This function deploys the documentation to the gh-pages branch of the repository.
# The main documentation that will be hosted on
# https://projecttorreypines.github.io/IFEdd.jl/stable
# will be built from latest release tagged with a version number.
# The development documentation that will be hosted on
# https://projecttorreypines.github.io/IFEdd.jl/dev
# will be built from the latest commit on the chosen devbranch argument below.
deploydocs(;
    repo="github.com/ProjectTorreyPines/IFEdd.jl.git",
    target="build",
    branch="gh-pages",
    devbranch="master",
    versions=["stable" => "v^", "v#.#"]
)
