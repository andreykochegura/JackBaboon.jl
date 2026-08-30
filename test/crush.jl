# SPDX-License-Identifier: MIT

include("common.jl")

enable_job_global_dbg_tracing()

@testset "Executor dispatcher crash" begin
    JackBaboon.async_execute!(
        :: Any,
        :: JackBaboon.Handle,
        :: Base.Semaphore,
        :: Symbol,
    ) = error("monkey attack on dispatcher level")
    let e = Executor()
        h = submit!(e) do c; end
        wait(e.dispatcher; throw=false)
        @test istaskfailed(e.dispatcher)
        wait(h; throw=false)
        @test isfailed(h)
        @test h.dbg_trace[end-1].state == HandleStates.Pending
        @test_throws CapturedException fetch(h)
        @test_throws ExecutorInternalError submit!(e) do c; end
        @test_throws ExecutorInternalError execute!(e) do c; end
        @test_throws ExecutorInternalError close(e)
    end
    JackBaboon.set_error_force!(
        :: JackBaboon.Handle,
        :: Any,
        :: Vector,
    ) = error("monkey attack on dispatcher cleanup")
    let e = Executor()
        h = submit!(e) do c; end
        wait(e.dispatcher; throw=false)
        @test istaskfailed(e.dispatcher)
        @test ispending(h)  # because set_error_force! is failed
        @test_throws CompositeException submit!(e) do c; end
        @test_throws CompositeException close(e)
    end
end
