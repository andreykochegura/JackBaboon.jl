# SPDX-License-Identifier: MIT
 
include("common.jl")

if Threads.nthreads(:default) + Threads.nthreads(:interactive) > Sys.CPU_THREADS
    error("Thread count exceeds available CPU threads; guaranteed execution cannot be provided.")
end

@testset "Backpressure" begin
    default = Executor(
        pool         = :default,
        capacity     = 1 << 20,
        concurrently = Threads.nthreads(:default),
    )
    interactive = Executor(
        pool         = :interactive,
        capacity     = 1 << 20,
        concurrently = Threads.nthreads(:interactive) - 1, # -1 for dispatcher
    )
    try
        job_num = 1 << 20
        interval = 0.1
        max_interval = 0.2
        target = 0.95
        event = Base.Event()
        intervals = sizehint!(Float64[], 10000)
        probe = submit!(interactive) do cancel_token
            wait(event)
            prev_ns = time_ns()
            while ! iscancelrequested(cancel_token)
                sleep(interval)
                curr_ns = time_ns()
                push!(intervals, (curr_ns - prev_ns) / 1e9)
                prev_ns = curr_ns
            end
        end
        notify(event)
        handles = Channel{Handle}(2*job_num)
        @sync begin
            Threads.@spawn :default for _ in 1:(job_num)
                put!(handles, submit!(interactive) do c
                    for _ in 1:5
                        do_work(1); yield()
                    end
                end)
            end
            Threads.@spawn :default for _ in 1:(job_num)
                put!(handles, submit!(default) do c
                    do_work(50)
                end)
            end
        end
        close(handles)
        for h in handles
            fetch(h)  # error detector
        end
        stop!(probe)
        wait(probe)
        @test mean(intervals .<= max_interval) >= target
    finally
        close(default)
        close(interactive)
    end
end
