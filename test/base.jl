# SPDX-License-Identifier: MIT

include("common.jl")

enable_job_global_tracing()

@testset "Smoke" begin
    with_executor() do e
        @test isopen(e)
        h = submit!(e) do c; "Jack" end
        @test h isa Handle
        @test fetch(h) == "Jack"
        r = execute!(e) do c; "Baboon" end
        @test r == "Baboon"
        @test_throws CapturedException fetch(submit!(e) do c; error() end)
        @test_throws CapturedException execute!(e) do c; error() end
        close(e)
        @test isclosed(e)
        close(e)
        @test isclosed(e)
    end
end

@testset "Arguments validation" begin
    @test_throws ArgumentError Executor(; pool = :qwerty)
    @test_throws ArgumentError Executor(; queue_capacity = 0)
    @test_throws ArgumentError Executor(; queue_capacity = -1)
    @test_throws ArgumentError Executor(; concurrently = 0)
    @test_throws ArgumentError Executor(; concurrently = -1)
    e = Executor()
    @test_throws MethodError submit!(e) do; end
    @test_throws MethodError submit!(e) do x, y; end
    close(e)
end

@testset "Cancellation" begin
    with_executor() do e
        @test !iscancelrequested(CancelToken())
        event = Base.Event(true)
        transit = submit!(e) do c
            wait(event)
            iscancelrequested(c)
        end
        wait_running(transit)
        stop!(transit)
        @test isstopping(transit)
        stop!(transit)
        @test isstopping(transit)
        notify(event)
        wait(transit)
        @test isstopped(transit)
        stop!(transit)
        @test isstopped(transit)
        @test fetch(transit) == true  # cancel token is requested
        stop!(transit)
        @test fetch(transit) == true
        check_trace(transit)
    end
end

@testset "Fetch error" begin
    with_executor(; queue_capacity=8, concurrently=2) do e
        try
            fetch(submit!(e) do c; error() end)
        catch ex
            @test ex isa CapturedException
            @test ex.ex isa ErrorException
            @test length(ex.processed_bt) > 0
        end
    end
end

@testset "Graceful shutdown" begin
    with_executor(; queue_capacity=8, concurrently=2) do e
        event = Base.Event()
        handles = Handle[]
        for _ in 1:8
            h = submit!(e) do c; wait(event) end
            push!(handles, h)
        end
        close(e)
        @test !isopen(e)
        @test isclosed(e)
        notify(event)
        wait.(handles)
        @test all(iscompleted.(handles))
        check_trace.(handles)
        @test_throws ExecutorClosedError submit!(e) do c; end
        @test_throws ExecutorClosedError execute!(e) do c; end
        close(e)
        @test !isopen(e)
        @test isclosed(e)
    end
end

@testset "Reject" begin
    with_executor(; queue_capacity=1, concurrently=1) do e
        event = Base.Event()
        h1 = submit!(e) do c; wait(event); end
        wait_running(h1)
        h2 = submit!(e) do c; wait(event); end
        wait_pending(h2)
        h3 = submit!(e) do c; wait(event); end
        handles = [h1,h2,h3]
        @test isfull(e.queue)
        @test_throws ExecutorRejectedError execute!(e) do c; end
        @test_throws ExecutorRejectedError submit!(e) do c; end
        notify(event)
        wait.(handles)
        @test all(iscompleted.(handles))
        check_trace.(handles)
    end
end

@testset "Concurrent" begin
    with_executor(; queue_capacity=1000, concurrently=2) do e
        counter = AtomicCounter()
        handles = Handle[]
        for _ in 1:e.queue_capacity
            try
                h = submit!(e) do c
                    try
                        ok = atomic_increment!(counter) <= e.concurrently
                        do_work(100)
                        ok
                    finally
                        atomic_decrement!(counter)
                    end
                end
                push!(handles, h)
            catch ex
                ex isa ExecutorRejectedError || rethrow()
            end
        end
        wait.(handles)
        @test @atomic(counter.x) == 0
        @test all(fetch.(handles))
        check_trace.(handles)
    end
end

@testset "Concurrent submission" begin
    with_executor(; queue_capacity=8, concurrently=2) do e
        job_num, task_num = 20, 100
        handles = Channel{Handle}(job_num * task_num)
        exceptions = Channel{Any}(job_num * task_num)
        @sync for _ in 1:task_num
            Threads.@spawn for _ in 1:job_num
                try
                    put!(handles, submit!(e) do ct; do_work(50) end)
                catch ex
                    put!(exceptions, ex)
                end
            end
        end
        close(handles)
        close(exceptions)
        h_num = 0
        e_num = 0
        for h in handles
            wait(h)
            @test iscompleted(h)
            check_trace(h)
            h_num += 1
        end
        for e in exceptions
            @test e isa ExecutorRejectedError
            e_num += 1
        end
        @test h_num > 0
        @test e_num > 0
        @test isempty(e.queue)
        @test e_num + h_num == job_num * task_num
    end
end

@testset "Concurrent submission and shutdown" begin
    with_executor(; queue_capacity=2000, concurrently=2) do e
        job_num, task_num = 20, 100
        handles = Channel{Handle}(e.queue_capacity)
        exceptions = Channel{Any}(e.queue_capacity)
        @sync for _ in 1:task_num
            Threads.@spawn begin
                for i in 1:job_num
                    try
                        put!(handles, submit!(e) do ct
                            do_work(50)
                        end)
                    catch ex
                        put!(exceptions, ex)
                    end
                    i > (job_num ÷ 2) && close(e)
                end
            end
        end
        close(handles)
        close(exceptions)
        h_num = 0
        e_num = 0
        for h in handles
            wait(h)
            @test iscompleted(h)
            @test fetch(h) isa Float64
            check_trace(h)
            h_num += 1
        end
        for ex in exceptions
            @test ex isa ExecutorClosedError
            e_num += 1
        end
        @test h_num > 0
        @test e_num > 0
        @test h_num + e_num == task_num * job_num
        @test isempty(e.queue)
        @test isclosed(e)
        @test_throws ExecutorClosedError submit!(e) do c; end
        @test_throws ExecutorClosedError execute!(e) do c;end
    end
end
