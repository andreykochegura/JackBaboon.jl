# SPDX-License-Identifier: MIT

include("common.jl")

check_thread_count()

enable_job_global_dbg_tracing()

@testset "Executor dispatcher crash" begin
    JackBaboon.async_execute!(
        @nospecialize(f),
        handle :: JackBaboon.Handle,
        sem    :: Base.Semaphore,
        pool   :: Symbol,
    ) = (sleep(0.1); error("monkey attack on dispatcher level"))
    let e = Executor()
        h = submit!(e) do c; end
        h2 = submit!(e) do c; end
        wait(e.dispatcher; throw=false)
        @test istaskfailed(e.dispatcher)
        wait(h2; throw=false)
        @test isfailed(h)
        @test isfailed(h2)
        @test h.dbg_trace[end-1].state == HandleStates.Running
        @test h2.dbg_trace[end-1].state == HandleStates.Queued
        @test_throws CapturedException fetch(h)
        @test_throws "Executor dispatcher error" fetch(h)
        @test_throws CapturedException fetch(h2)
        @test_throws "Executor dispatcher error" fetch(h2)
        @test_throws ExecutorInternalError submit!(e) do c; end
        @test_throws "Executor dispatcher error" submit!(e) do c; end
        @test_throws ExecutorInternalError execute!(e) do c; end
        @test_throws "Executor dispatcher error" execute!(e) do c; end
        @test_throws ExecutorInternalError close(e)
        @test_throws "Executor dispatcher error" close(e)
    end
end

disable_job_global_dbg_tracing()
