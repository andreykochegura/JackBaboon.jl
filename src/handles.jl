# SPDX-License-Identifier: MIT

module HandleStates
using ..StateMachines
@enum State::UInt8 begin
    Queued
    Pending
    Canceled
    Running
    Completed
    Stopping
    Stopped
    Failed
end
const STATE_MACHINE = StateMachine(
    Queued     => [Pending, Canceled, Failed],
    Pending    => [Running, Canceled, Failed],
    Canceled   => [],
    Running    => [Completed, Stopping, Failed],
    Completed  => [],
    Stopping   => [Stopped, Failed],
    Stopped    => [],
    Failed     => [],
)
can_transit(from::State, to::State) =
    StateMachines.can_transit(STATE_MACHINE, from, to)
check_transit(from::State, to::State) =
    StateMachines.check_transit(STATE_MACHINE, from, to)
can_reach(from::State, to::State) = 
    StateMachines.can_reach(STATE_MACHINE, from, to)
is_terminal(state::State) =
    StateMachines.is_terminal(STATE_MACHINE, state)
end


struct JobEvent
    job_uuid     :: UUID
    sequence     :: UInt64
    timestamp    :: UInt64
    cancel_flag  :: Bool
    result       :: Any
    error        :: Any
    state       :: HandleStates.State
end

mutable struct Handle
    const job_uuid     :: UUID
    const cancel_token :: CancelToken
    const cond         :: Threads.Condition
    const lock         :: ReentrantLock
    const __dbg        :: Bool
    const dbg_trace    :: Vector{JobEvent}
    result             :: Union{Nothing, Any}  # for illustration
    error              :: Union{Nothing, Exception}  # CapturedException <: Exception
    @atomic state     :: HandleStates.State
end

function Base.show(io::IO, h::Handle)
    state = @atomic h.state
    print(io, "JackBaboon.Handle(")
    printstyled(io, "#=", state, " [", string(h.job_uuid)[end-7:end], "]=#"; color=:light_black)
    print(io, ")")
end

function Handle()
    lock = ReentrantLock()
    cond = Threads.Condition(lock)
    handle = Handle(
        uuid4(),
        CancelToken(),
        cond,
        lock,
        is_job_global_dbg_tracing_on(),
        JobEvent[],
        nothing,
        nothing,
        HandleStates.Queued,
    )
    trace_locked!(handle)
    return handle
end

function wait_state(h::Handle, state::HandleStates.State)
    lock(h.lock) do
        while ! (@atomic(h.state) == state || HandleStates.can_reach(state, @atomic(h.state)))
            wait(h.cond)
        end
    end
end

for state in instances(HandleStates.State)
    name = Symbol(:wait_, lowercase(string(state)))
    @eval $name(h::Handle) = wait_state(h, $state)
end


"""
    isqueued(handle::Handle)::Bool

Returns `true` if the job is in the executor queue.
"""
isqueued(handle::Handle)::Bool =
    HandleStates.Queued == @atomic handle.state


"""
    ispending(handle::Handle)::Bool

Returns `true` if the job is pending execution.
"""
ispending(handle::Handle)::Bool =
    HandleStates.Pending == @atomic handle.state


"""
    isrunning(handle::Handle)::Bool

Returns `true` if the job is executing.
"""
isrunning(handle::Handle)::Bool =
    HandleStates.Running == @atomic handle.state


"""
    iscompleted(handle::Handle)::Bool

Returns `true` if the job completed successfully.
"""
iscompleted(handle::Handle)::Bool =
    HandleStates.Completed == @atomic handle.state


"""
    isfailed(handle::Handle)::Bool

Returns `true` if the job has failed.
"""
isfailed(handle::Handle)::Bool =
    HandleStates.Failed == @atomic handle.state


"""
    isstopping(handle::Handle)::Bool

Returns `true` if the running job is stopping.
"""
isstopping(handle::Handle)::Bool =
    HandleStates.Stopping == @atomic handle.state


"""
    isstopped(handle::Handle)::Bool

Returns `true` if the job is stopped.
"""
isstopped(handle::Handle)::Bool =
    HandleStates.Stopped == @atomic handle.state


"""
    iscanceled(handle::Handle)::Bool

Returns `true` if the job was stopped before it was started.
"""
iscanceled(handle::Handle)::Bool =
    HandleStates.Canceled == @atomic handle.state


"""
    isfinal(handle::Handle)::Bool

Returns `true` if the job is in a final state.
"""
isfinal(handle::Handle)::Bool =
    HandleStates.is_terminal(@atomic(handle.state))


function transit_locked!(handle::Handle, state::HandleStates.State)
    HandleStates.check_transit(@atomic(handle.state), state)
    @atomic handle.state = state
    handle.__dbg && trace_locked!(handle)
    notify(handle.cond; all=true, error=false)
    return handle
end

function trace_locked!(handle::Handle)
    push!(handle.dbg_trace, JobEvent(
        handle.job_uuid,
        next_job_trace_global_sequence(),
        time_ns(),   # NOTE: process-local monotonic clock and reset every few years
        iscancelrequested(handle.cancel_token),
        handle.result,
        handle.error,
        @atomic(handle.state),
    ))
    return handle
end

function set_failed!(handle::Handle, ex, bt::Vector=[])
    lock(handle.lock) do
        handle.error = CapturedException(ex, bt)
        transit_locked!(handle, HandleStates.Failed)
    end
    return handle
end

function try_failed!(handle::Handle, ex, bt::Vector=[])
    lock(handle.lock) do 
        iscanceled(handle) && return false
        handle.error = CapturedException(ex, bt)
        transit_locked!(handle, HandleStates.Failed)
        return true
    end
end

function try_pending!(handle::Handle)::Bool
    lock(handle.lock) do
        iscanceled(handle) && return false
        transit_locked!(handle, HandleStates.Pending)
        return true
    end
end

function try_running!(handle::Handle)::Bool
    lock(handle.lock) do
        iscanceled(handle) && return false
        transit_locked!(handle, HandleStates.Running)
        return true
    end
end

function async_execute!(@nospecialize(f), handle::Handle, sem::Semaphore, pool::Symbol, metrics::Metrics)::Task
    Threads.@spawn pool begin
        try
            result = try
                Base.invokelatest(f, handle.cancel_token)  # adds ~50 ns
            catch ex
                set_failed!(handle, ex, catch_backtrace())
                @atomic metrics.failed += 1
                nothing
            end
            lock(handle.lock) do
                if isrunning(handle)
                    handle.result = result
                    transit_locked!(handle, HandleStates.Completed)
                    @atomic metrics.completed += 1
                elseif isstopping(handle)
                    handle.result = result
                    transit_locked!(handle, HandleStates.Stopped)
                    @atomic metrics.stopped += 1
                elseif isfailed(handle)
                    # skip failed
                else
                    set_failed!(handle, ExecutorInternalError(
                        "Unexpected behavior: wrong handle state: `$(@atomic(handle.state))`",
                    ))
                end
            end
        catch ex
            set_failed!(handle, ExecutorInternalError("Unexpected behavior: unknown error", ex, catch_backtrace()))
        finally
            release(sem)
            @atomic metrics.active -= 1
        end
    end
end


"""
    stop!(handle::Handle)::Handle

Request a cancel; the job completion is a user responsibility; queued stopped job remains in the queue before it is retrieved and skipped by the dispatcher.

# Examples

```julia-repl
julia> handle = submit!(executor) do cancel_token
           while ! iscancelrequested(cancel_token)
                sleep(0.1)
           end
           iscancelrequested ? "job is stopped" : "job is completed"
       end;

julia> stop!(handle);

julia> fetch(handle)
"job is stopped"
```
"""
function stop!(handle::Handle)
    lock(handle.lock) do
        stop_locked!(handle)
    end
    return handle
end

function stop_locked!(handle::Handle)
    isfinal(handle) && return handle
    isstopping(handle) && return handle
    @atomic handle.cancel_token.request = true
    state = isrunning(handle) ?
        HandleStates.Stopping :
        HandleStates.Canceled
    transit_locked!(handle, state)
    return handle
end


"""
    ExecutorJobCancelledError(msg::AbstractString)

Thrown on fetch result from cancelling or cancelled job.
"""
struct ExecutorJobCancelledError <: Exception
    msg :: AbstractString
end

function Base.showerror(io::IO, e::ExecutorJobCancelledError)
    print(io, "ExecutorJobCancelledError: ", e.msg)
end


"""
    wait(handle::Handle; throw=true)::Nothing

Wait job finalize.
"""
function Base.wait(handle::Handle; throw::Bool=true)::Nothing
    lock(handle.lock) do 
        wait_locked!(handle; throw)
    end
    return nothing
end

function wait_locked!(handle::Handle; throw::Bool)
    while ! isfinal(handle)
        wait(handle.cond)
    end
    throw && isfailed(handle) && Base.throw(handle.error)
    return nothing
end


"""
    fetch(handle::Handle)::Any

Wait job finalize and fetch result or throw error.
"""
function Base.fetch(handle::Handle)
    lock(handle.lock) do 
        wait_locked!(handle; throw=true)
        (iscompleted(handle) || isstopped(handle))&& return handle.result
        iscanceled(handle) && throw(ExecutorJobCancelledError(
            "Job was cancelled",
        ))
        throw(ExecutorInternalError(
            "Wrong job state: `$(@atomic(handle.state))`"
        ))
    end
end
