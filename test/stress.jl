# SPDX-License-Identifier: MIT

include("common.jl")

@testset "Mini Stress" begin
    job_num = 1 << 20
    e = Executor(
        pool         = :default,
        capacity   = job_num ÷ 2,
        concurrently = Threads.nthreads(:default) * 2,
    )
    try
        handles = Handle[]
        exceptions = Any[]
        for _ in 1:job_num
            try
                h = submit!(e) do c
                    [(yield();do_work(10)) for _ in 1:5]
                end
                push!(handles, h)
            catch ex
                push!(exceptions, ex)
            end
        end
        wait.(handles)
        @test all(isa.(exceptions, ExecutorRejectedError))
        @test all(iscompleted.(handles))
    finally
        close(e)
    end
end
