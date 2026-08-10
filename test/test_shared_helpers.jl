using Test
using IFEdd
using IMASdd
using JSON

@testset "shared_helpers" begin

    @testset "GeneratorError showerror" begin
        e = IFEdd.GeneratorError(:bad_supertype, "Unknown")
        io = IOBuffer()
        Base.showerror(io, e)
        s = String(take!(io))
        @test occursin("bad_supertype", s)
        @test occursin("Unknown", s)

        e2 = IFEdd.GeneratorError(:pidlock_timeout, nothing)
        io = IOBuffer()
        Base.showerror(io, e2)
        @test occursin("pidlock_timeout", String(take!(io)))
    end

    @testset "atomic_write LF normalization" begin
        d = mktempdir()
        p = joinpath(d, "out.txt")
        IFEdd.atomic_write(p, "line1\r\nline2\r\n")
        bytes = read(p)
        @test all(b -> b != UInt8('\r'), bytes)
        @test String(bytes) == "line1\nline2\n"
    end

    @testset "atomic_write creates dirs and overwrites" begin
        d = mktempdir()
        nested = joinpath(d, "sub", "deeper", "file.txt")
        IFEdd.atomic_write(nested, "hello\n")
        @test read(nested, String) == "hello\n"
        # overwrite
        IFEdd.atomic_write(nested, "world\n")
        @test read(nested, String) == "world\n"
    end

    @testset "with_generator_lock acquires and releases" begin
        d = mktempdir()
        acquired = false
        result = IFEdd.with_generator_lock(d) do
            acquired = true
            return 42
        end
        @test acquired
        @test result == 42
        # Lock file should be cleaned up
        @test !isfile(joinpath(d, ".ifedd_gen.lock"))
    end

    @testset "with_generator_lock serializes concurrent callers" begin
        d = mktempdir()
        order = Int[]
        olock = ReentrantLock()
        t1 = Threads.@spawn IFEdd.with_generator_lock(d; wait_timeout=10) do
            lock(olock) do; push!(order, 1) end
            sleep(0.3)
            lock(olock) do; push!(order, 2) end
        end
        # let t1 grab the lock first
        sleep(0.05)
        t2 = Threads.@spawn IFEdd.with_generator_lock(d; wait_timeout=10) do
            lock(olock) do; push!(order, 3) end
        end
        wait(t1); wait(t2)
        # t2 must observe t1's full critical section before entering
        @test findfirst(==(3), order) > findfirst(==(2), order)
    end

    @testset "hash_file determinism" begin
        d = mktempdir()
        p = joinpath(d, "f.txt")
        write(p, "abc\n")
        h1 = IFEdd.hash_file(p)
        h2 = IFEdd.hash_file(p)
        @test h1 == h2
        @test length(h1) == 64   # sha256 hex
    end

    @testset "canonicalize_json sorts nested keys" begin
        d1 = Dict("b" => 1, "a" => Dict("d" => 2, "c" => 3))
        d2 = Dict("a" => Dict("c" => 3, "d" => 2), "b" => 1)
        @test IFEdd.canonicalize_json(d1) == IFEdd.canonicalize_json(d2)
    end

    @testset "hash_canonical_json is order-independent" begin
        d1 = Dict("b" => 1, "a" => Dict("d" => 2, "c" => 3))
        d2 = Dict("a" => Dict("c" => 3, "d" => 2), "b" => 1)
        @test IFEdd.hash_canonical_json(d1) == IFEdd.hash_canonical_json(d2)
        # changing a value MUST change the hash
        d3 = Dict("b" => 1, "a" => Dict("d" => 2, "c" => 99))
        @test IFEdd.hash_canonical_json(d1) != IFEdd.hash_canonical_json(d3)
    end

    @testset "key_owner extracts module from UnionAll key" begin
        k = (IFEdd.summary, :time)
        @test IFEdd.key_owner(k) === IFEdd
        # Sweep all _all_info keys; every owner must be IMASdd or IFEdd
        owners = unique([IFEdd.key_owner(k) for k in keys(IMASdd._all_info)])
        @test IMASdd in owners
        @test IFEdd in owners
    end

    @testset "info_field_names returns 6 fields in pinned order" begin
        fns = IFEdd.info_field_names()
        @test fns == (:coordinates, :units, :data_type, :documentation,
                      :extra, :cocos_transform)
        @test length(fns) == 6
    end

    @testset "housekeeping_field_set / order" begin
        s = IFEdd.housekeeping_field_set(IFEdd.summary{Float64})
        o = IFEdd.housekeeping_field_order(IFEdd.summary{Float64})
        # All housekeeping names start with `_`
        @test all(startswith(string(n), "_") for n in s)
        @test Set(o) == s
        # Required for any leaf IDS (per current GenerateDD output)
        for required in (:_name, :_filled, :_frozen,
                         :_threads_lock, :_in_expression, :_parent)
            @test required in s
        end
        # Container has the extra `_aux` Dict; leaves don't.
        @test :_aux in IFEdd.housekeeping_field_set(IFEdd.dd{Float64})
        # Order matches fieldnames order
        @test o == [n for n in fieldnames(IFEdd.summary{Float64}) if startswith(string(n), "_")]
    end

    @testset "read_supertypes_from_schemas reads IFEdd's own JSON" begin
        dir = joinpath(pkgdir(IFEdd), "data_dictionary", "data_structures_extra")
        supertypes = IFEdd.read_supertypes_from_schemas(dir,
            ["summary", "build", "driver"])
        @test supertypes["summary"] == "AbstractIFESummary"
        @test supertypes["build"]   == "AbstractIFEBuild"
        @test supertypes["driver"]  == "AbstractIFEDriver"
    end

    @testset "read_supertypes_from_schemas raises :schema_dir_missing" begin
        bad_dir = tempname()
        err = try
            IFEdd.read_supertypes_from_schemas(bad_dir, ["whatever"])
            nothing
        catch e
            e
        end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :schema_dir_missing
    end

    @testset "read_supertypes_from_schemas raises :malformed_json" begin
        d = mktempdir()
        write(joinpath(d, "broken.json"), "this is not json {")
        err = try
            IFEdd.read_supertypes_from_schemas(d, ["broken"])
            nothing
        catch e
            e
        end
        @test err isa IFEdd.GeneratorError
        @test err.reason === :malformed_json
    end

    @testset "read_supertypes_from_schemas silently skips no-supertype JSON" begin
        d = mktempdir()
        write(joinpath(d, "noattr.json"),
              JSON.json(Dict("noattr" => Dict("documentation" => "no supertype"))))
        out = IFEdd.read_supertypes_from_schemas(d, ["noattr"])
        @test isempty(out)
    end

end
