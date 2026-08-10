using Test
using IFEdd
using IMASdd
using JSON

# `make_synthetic_schema` is defined in test_user_dd_emit.jl
# (included earlier from runtests.jl), so it's in scope here as a global.

@testset "@bake_dd macro" begin

    @testset "ephemeral bake: binds type at caller scope" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="bk_basic")
        IFEdd.@bake_dd dd_bk_basic = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_basic),
        )
        @test dd_bk_basic isa Type
        @test dd_bk_basic <: IFEdd.AbstractIFEDD
        @test dd_bk_basic <: IMASdd.DD
        d = dd_bk_basic()
        @test d isa IMASdd.DD{Float64}
        @test d.summary isa IFEdd.AbstractIFESummary{Float64}
        # bake_source files exist
        src = IFEdd.bake_source(dd_bk_basic)
        @test isfile(src.idstypes)
        @test isfile(src.dd)
        @test isfile(src.manifest)
    end

    @testset "hidden module binds IMASdd/IFEdd without `using`" begin
        # Regression: the hidden module belongs to no package, so `using
        # IMASdd` there resolves against the CALLER's active project. A
        # project that depends on IFEdd alone would fail to bake. The
        # modules must be bound directly instead.
        td = mktempdir()
        sd = make_synthetic_schema(td; name="bk_bind")
        IFEdd.@bake_dd dd_bk_bind = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_bind),
        )
        hidden = parentmodule(Base.unwrap_unionall(dd_bk_bind))
        @test isdefined(hidden, :IMASdd)
        @test isdefined(hidden, :IFEdd)
        @test getfield(hidden, :IMASdd) === IMASdd
        @test getfield(hidden, :IFEdd) === IFEdd
    end

    @testset "field write/read round-trip via baked type" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="bk_rt")
        IFEdd.@bake_dd dd_bk_rt = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_rt),
        )
        d = dd_bk_rt()
        d.summary.yield = 9.0
        @test d.summary.yield == 9.0
        @test getfield(d, :_filled).summary == true
    end

    @testset "cache: identical re-bake returns same type" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="bk_cache")
        IFEdd.@bake_dd dd_bk_cache = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_cache),
        )
        t1 = dd_bk_cache
        # Re-bake with identical inputs (same name, same schema, same bindings)
        IFEdd.@bake_dd dd_bk_cache = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_cache),
        )
        @test t1 === dd_bk_cache
    end

    @testset "distinct names → distinct types" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="bk_dual")
        IFEdd.@bake_dd dd_bk_d1 = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_dual),
        )
        IFEdd.@bake_dd dd_bk_d2 = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_dual),
        )
        @test dd_bk_d1 !== dd_bk_d2  # different cache keys (target_module differs)
        @test dd_bk_d1 <: IMASdd.DD
        @test dd_bk_d2 <: IMASdd.DD
    end

    @testset "persistent bake: source files at output_dir" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="bk_persist")
        out_dir = joinpath(td, "persist_out")
        IFEdd.@bake_dd dd_bk_persist = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_persist),
            output_dir    = out_dir,
        )
        d = dd_bk_persist()
        @test d isa IMASdd.DD{Float64}
        # Files should live in out_dir, not /tmp
        src = IFEdd.bake_source(dd_bk_persist)
        @test startswith(src.idstypes, out_dir)
        @test startswith(src.dd, out_dir)
        @test isfile(src.idstypes)
    end

    @testset "bake_manifest returns the manifest dict" begin
        td = mktempdir()
        sd = make_synthetic_schema(td; name="bk_man")
        IFEdd.@bake_dd dd_bk_man = (
            schema_dir    = sd,
            slot_bindings = Dict(:summary => :bk_man),
        )
        m = IFEdd.bake_manifest(dd_bk_man)
        @test m["target_module"] == "dd_bk_man"
        @test m["slot_bindings"]["summary"]["concrete"] == "bk_man"
        @test m["slot_bindings"]["summary"]["source"] == "user"
        @test haskey(m, "ifedd_abstracts_sha256")
    end

    @testset "bake_manifest / bake_source reject non-baked types" begin
        @test_throws ArgumentError IFEdd.bake_manifest(IFEdd.dd)
        @test_throws ArgumentError IFEdd.bake_source(IFEdd.dd)
    end

    @testset "macro rejects malformed input" begin
        # Wrong shape (not an assignment) — macro `error`s at expansion
        @test_throws LoadError @eval IFEdd.@bake_dd (foo, bar)
    end

end
