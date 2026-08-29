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
    Queued     => [Pending, Canceled],
    Pending    => [Running, Canceled],
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
can_precede(from::State, to::State) = 
    StateMachines.can_precede(STATE_MACHINE, from, to)
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
    result             :: Union{Nothing, Any}  # not baboon code - it's for illustration :)
    error              :: Union{Nothing, Exception}
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
        is_job_global_tracing_on(),
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
        while ! (@atomic(h.state) == state || HandleStates.can_precede(@atomic(h.state), state))
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

Returns `true` if job in executor queue.
"""
isqueued(handle::Handle)::Bool =
    HandleStates.Queued == @atomic handle.state


"""
    ispending(handle::Handle)::Bool

Returns `true` if job is pending execution.
"""
ispending(handle::Handle)::Bool =
    HandleStates.Pending == @atomic handle.state


"""
    isrunning(handle::Handle)::Bool

Returns `true` if job task is executing.
"""
isrunning(handle::Handle)::Bool =
    HandleStates.Running == @atomic handle.state


"""
    iscompleted(handle::Handle)::Bool

Returns `true` if job task completed successfully.
"""
iscompleted(handle::Handle)::Bool =
    HandleStates.Completed == @atomic handle.state


"""
    isfailed(handle::Handle)::Bool

Returns `true` if job task is failed.
"""
isfailed(handle::Handle)::Bool =
    HandleStates.Failed == @atomic handle.state


"""
    isstopping(handle::Handle)::Bool

Returns `true` if running job stopping in progress.
"""
isstopping(handle::Handle)::Bool =
    HandleStates.Stopping == @atomic handle.state


"""
    isstopped(handle::Handle)::Bool

Returns `true` if job is stopped.
"""
isstopped(handle::Handle)::Bool =
    HandleStates.Stopped == @atomic handle.state


"""
    iscanceled(handle::Handle)::Bool

Returns `true` if job was canceled and task is completed.
"""
iscanceled(handle::Handle)::Bool =
    HandleStates.Canceled == @atomic handle.state


"""
    isfinal(handle::Handle)::Bool

Returns `true` if job in final state.
"""
isfinal(handle::Handle)::Bool =
    HandleStates.is_terminal(@atomic(handle.state))


function set_state_locked!(handle::Handle, state::HandleStates.State; force::Bool=false)
    force || HandleStates.check_transit(@atomic(handle.state), state)
    @atomic handle.state = state
    trace_locked!(handle)
    notify(handle.cond; all=true, error=false)
    return handle
end

function trace_locked!(handle::Handle)
    handle.__dbg || return handle
    push!(handle.dbg_trace, JobEvent(
        handle.job_uuid,
        next_job_trace_global_sequence(),
        time_ns(),   # NOTE: not global ordering primitive and reset every few years
        iscancelrequested(handle.cancel_token),
        handle.result,
        handle.error,
        @atomic(handle.state),
    ))
    return handle
end

function set_state!(handle::Handle, state::HandleStates.State; force::Bool=false)
    lock(handle.lock) do 
        set_state_locked!(handle, state; force)
    end
    return handle
end

function set_failed!(handle::Handle, ex, bt::Vector=[]; force::Bool=false)
    lock(handle.lock) do
        handle.error = CapturedException(ex, bt)
        set_state_locked!(handle, HandleStates.Failed; force)
    end
    return handle
end

function set_error_force!(handle::Handle, ex, bt::Vector=[])
    set_failed!(handle, ex, bt; force=true)
    return handle
end

function try_pending!(handle::Handle)::Bool
    lock(handle.lock) do
        iscanceled(handle) && return false
        set_state_locked!(handle, HandleStates.Pending)
        return true
    end
end

function try_running!(handle::Handle)::Bool
    lock(handle.lock) do
        iscanceled(handle) && return false
        set_state_locked!(handle, HandleStates.Running)
        return true
    end
end

function async_execute!(@nospecialize(f), handle::Handle, sem::Semaphore, pool::Symbol)::Nothing
    if ! try_running!(handle)
        release(sem)
        return nothing  # skip canceled
    end
    Threads.@spawn pool begin  # 
        try
            result = try
                Base.invokelatest(f, handle.cancel_token)
            catch ex
                set_failed!(handle, ex, catch_backtrace())
                nothing
            end
            lock(handle.lock) do
                if isrunning(handle)
                    handle.result = result
                    set_state_locked!(handle, HandleStates.Completed)
                elseif isstopping(handle)
                    handle.result = result
                    set_state_locked!(handle, HandleStates.Stopped)
                elseif isfailed(handle)
                    # skip failed
                else
                    set_error_force!(handle, ExecutorInternalError(
                        "Wrong handle state: `$(@atomic(handle.state))`",
                    ))
                end
            end
        catch ex
            set_error_force!(handle, ExecutorInternalError(
                "Unknown error", ex, catch_backtrace()
            ))
        finally
            release(sem)
        end
    end
    return nothing
end


"""
    stop!(handle::Handle)::Handle

Request a cancel; the job completion is a user responsibility.

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
    set_state_locked!(handle, state)
    return handle
end


"""
    JobCancelledError(msg::AbstractString)

Thrown on fetch result from cancelling or cancelled job.
"""
struct JobCancelledError <: Exception
    msg :: AbstractString
end

function Base.showerror(io::IO, e::JobCancelledError)
    print(io, "JobCancelledError: ", e.msg)
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
        iscanceled(handle) && throw(JobCancelledError(
            "Job was cancelled",
        ))
        throw(ExecutorInternalError(
            "Wrong job state: `$(@atomic(handle.state))`"
        ))
    end
end
