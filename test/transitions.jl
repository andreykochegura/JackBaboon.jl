# SPDX-License-Identifier: MIT

include("common.jl")

enable_job_global_tracing()

@testset "Queued → Pending → Running → Completed" begin
    with_executor(; queue_capacity=1, concurrently=1) do e
        event = Base.Event(true)
        h1 = submit!(e) do c; wait(event) end
        wait_running(h1)
        h2 = submit!(e) do c; wait(event) end
        wait_pending(h2)
        transit = submit!(e) do c; wait(event) end
        @test isqueued(transit)
        notify(event)
        wait_pending(transit)
        @test ispending(transit)
        notify(event)
        wait_running(transit)
        @test isrunning(transit)
        notify(event)
        wait(transit)
        @test iscompleted(transit)
        stop!(transit)
        @test iscompleted(transit)
        check_trace(transit)
    end
end

@testset "Queued → Canceled" begin
    with_executor(; queue_capacity=1, concurrently=1) do e
        event = Base.Event()
        h1 = submit!(e) do c; wait(event) end
        wait_running(h1)
        h2 = submit!(e) do c; end
        wait_pending(h2)
        transit = submit!(e) do c; end
        @test isqueued(transit)
        stop!(transit)
        wait(transit)
        @test iscanceled(transit)
        stop!(transit)
        @test iscanceled(transit)
        notify(event)
        check_trace(transit)
    end
end

@testset "Pending → Canceled" begin
    with_executor(; queue_capacity=1, concurrently=1) do e
        event = Base.Event()
        h = submit!(e) do c; wait(event) end
        wait_running(h)
        transit = submit!(e) do c; end
        wait_pending(transit)
        @test ispending(transit)
        stop!(transit)
        wait(transit)
        @test iscanceled(transit)
        stop!(transit)
        @test iscanceled(transit)
        notify(event)
        check_trace(transit)
    end
end

@testset "Running → Stopping → Stopped" begin
    with_executor(; queue_capacity=1, concurrently=1) do e
        event = Base.Event()
        transit = submit!(e) do c; wait(event) end
        wait_running(transit)
        @test isrunning(transit)
        stop!(transit)
        @test isstopping(transit)
        stop!(transit)
        @test isstopping(transit)
        notify(event)
        wait(transit)
        @test isstopped(transit)
        stop!(transit)
        @test isstopped(transit)
        check_trace(transit)
    end
end

@testset "Running → Fail" begin
    with_executor(; queue_capacity=1, concurrently=1) do e
        event = Base.Event()
        transit = submit!(e) do c; wait(event); error() end
        wait_running(transit)
        @test isrunning(transit)
        notify(event)
        wait(transit; throw=false)
        @test isfailed(transit)
        stop!(transit)
        @test isfailed(transit)
        check_trace(transit)
    end
end

@testset "Running → Stopping → Fail" begin
    with_executor(; queue_capacity=1, concurrently=1) do e
        event = Base.Event()
        transit = submit!(e) do c; wait(event); error() end
        wait_running(transit)
        @test isrunning(transit)
        stop!(transit)
        @test isstopping(transit)
        stop!(transit)
        @test isstopping(transit)
        notify(event)
        wait(transit; throw=false)
        @test isfailed(transit)
        stop!(transit)
        @test isfailed(transit)
        check_trace(transit)
    end
end
