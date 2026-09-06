# SPDX-License-Identifier: MIT

using Test
using Random
using JackBaboon
using JackBaboon:
    Handle,
    HandleStates,
    with_executor,
    wait_queued,
    wait_pending,
    wait_running,
    wait_completed,
    wait_failed,
    wait_stopping,
    wait_stopped,
    wait_canceled,
    CancelToken,
    enable_job_global_dbg_tracing,
    disable_job_global_dbg_tracing


function check_thread_count()
    n = Threads.nthreads(:default) + Threads.nthreads(:interactive)
    n <= Sys.CPU_THREADS && return nothing
    @warn("""Thread count exceeds available CPU threads;
    $(@__FILE__) guaranteed execution cannot be provided;
    Threads.nthreads(:default)=$(Threads.nthreads(:default));
    Threads.nthreads(:interactive)=$(Threads.nthreads(:interactive));
    Sys.CPU_THREADS=$(Sys.CPU_THREADS);""")
    exit()
end

mutable struct AtomicCounter
    @atomic x :: Int
    AtomicCounter() = new(0)
end
atomic_increment!(a::AtomicCounter) = @atomic a.x += 1
atomic_decrement!(a::AtomicCounter) = @atomic a.x -= 1

mean(a) = sum(a) / length(a)

function do_work(work_size)::Float64
    n = work_size
    return sum(rand(n, n))
end

function check_trace(h::JackBaboon.Handle)
    @test ! isempty(h.dbg_trace)
    @test h.dbg_trace[1].state == HandleStates.Queued
    for (from, to) in zip(h.dbg_trace, @view h.dbg_trace[2:end])
        @test HandleStates.can_transit(from.state, to.state)
        @test from.sequence < to.sequence
        @test from.job_uuid == to.job_uuid
        @test from.cancel_flag <= to.cancel_flag
        @test from.result === nothing
        if to.result !== nothing
            @test to.state in (HandleStates.Completed, HandleStates.Stopped)
        end
        if to.error !== nothing
            @test to.state == HandleStates.Failed
        end
        if from.error !== nothing 
            @test from.state ==HandleStates.Failed
        end
    end
    if isfinal(h)
        @test h.dbg_trace[end].state == h.state
    end
end
