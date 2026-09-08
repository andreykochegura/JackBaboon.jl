# SPDX-License-Identifier: MIT

include("common.jl")

check_thread_count(exit_process=true)

@testset "Metrics" begin
    with_executor(concurrently=1, queue_capacity=2) do e
        event = Base.Event(true)
        handles = Handle[]
        push!(handles, submit!(e) do c; wait(event) end)
        wait_running(handles[1])
        push!(handles, submit!(e) do c; error() end)
        wait_pending(handles[2])
        push!(handles, submit!(e) do c; end)
        push!(handles, submit!(e) do c; wait(event) end)
        try submit!(e)  do c; end; catch; end
        try execute!(e) do c; end; catch; end
        m = metrics(e)
        @test m.rejected == 2
        @test m.queued == 4
        @test m.started == 1
        @test m.completed == 0
        @test m.stopped == 0
        @test m.cancelled == 0
        @test m.failed == 0
        @test m.backlog == 2
        @test m.active == 1
        @test m.concurrently == 1
        @test m.queue_capacity == 2
        stop!(handles[3])
        notify(event)
        wait_running(handles[4])
        stop!(handles[4])
        notify(event)
        wait.(handles; throw=false)
        m = metrics(e)
        @test m.rejected == 2
        @test m.queued == 4
        @test m.started == 3
        @test m.completed == 1
        @test m.stopped == 1
        @test m.cancelled == 1
        @test m.failed == 1
        @test m.backlog == 0
        @test m.active == 0
        @test m.concurrently == 1
        @test m.queue_capacity == 2
    end
end
