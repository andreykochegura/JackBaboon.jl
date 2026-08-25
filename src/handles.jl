# SPDX-License-Identifier: MIT

module HandleStatuses
    @enum Status::UInt8 begin
        Queued
        Pending
        Running
        Completed
        Failed
        Cancelling
        Canceled
    end
    const TRANSITIONS = Base.ImmutableDict(
        Queued     => [Pending, Canceled],
        Pending    => [Running, Canceled],
        Running    => [Completed, Cancelling, Failed],
        Cancelling => [Canceled, Failed],
        Completed  => [],
        Failed     => [],
        Canceled   => [],
    )
end

struct HandleEvent
    uuid         :: UUID
    sequence     :: UInt64
    timestamp    :: UInt64
    cancel_flag  :: Bool
    result       :: Union{Nothing, Any}
    error        :: Union{Nothing, Any}
    trace        :: Union{Nothing, Vector}
    status       :: HandleStatuses.Status
end

mutable struct Handle
    const uuid         :: UUID
    const cancel_token :: CancelToken
    const cond         :: Threads.Condition
    const lock         :: ReentrantLock
    const __dbg        :: Bool
    const dbg_trace    :: Vector{HandleEvent}
    result             :: Union{Nothing, Any}
    error              :: Union{Nothing, Any}
    trace              :: Union{Nothing, Vector}
    @atomic status     :: HandleStatuses.Status
end

function Handle(; __dbg::Bool)
    lock = ReentrantLock()
    cond = Threads.Condition(lock)
    handle = Handle(
        uuid4(),
        CancelToken(),
        cond,
        lock,
        __dbg,
        [],
        nothing,
        nothing,
        nothing,
        HandleStatuses.Queued,
    )
    trace!(handle)
    return handle
end

struct Job
    f
    handle :: Handle
end

Job(@nospecialize(f); __dbg::Bool) = Job(f, Handle(; __dbg))

"""
    isqueued(handle::Handle)::Bool

Returns `true` if job in `Executor` queue.
"""
isqueued(handle::Handle)::Bool =
    HandleStatuses.Queued == @atomic handle.status

"""
    ispending(handle::Handle)::Bool

Returns `true` if job is pending execution.
"""
ispending(handle::Handle)::Bool =
    HandleStatuses.Pending == @atomic handle.status

"""
    isrunning(handle::Handle)::Bool

Returns `true` if job task is executing.
"""
isrunning(handle::Handle)::Bool =
    HandleStatuses.Running == @atomic handle.status

"""
    iscompleted(handle::Handle)::Bool

Returns `true` if job task completed successfully.
"""
iscompleted(handle::Handle)::Bool =
    HandleStatuses.Completed == @atomic handle.status

"""
    isfailed(handle::Handle)::Bool

Returns `true` if job task is failed.
"""
isfailed(handle::Handle)::Bool =
    HandleStatuses.Failed == @atomic handle.status

"""
    iscancelling(handle::Handle)::Bool

Returns `true` if running job cancellation in progress.
"""
iscancelling(handle::Handle)::Bool =
    HandleStatuses.Cancelling == @atomic handle.status

"""
    iscanceled(handle::Handle)::Bool

Returns `true` if job was canceled and task is completed.
"""
iscanceled(handle::Handle)::Bool =
    HandleStatuses.Canceled == @atomic handle.status

"""
    isfinal(handle::Handle)::Bool

Returns `true` if job in final status.
"""
isfinal(handle::Handle)::Bool =
    iscompleted(handle) || isfailed(handle) || iscanceled(handle)


mutable struct HandleTraceSequence
    @atomic x :: UInt64
end

const HANDLE_TRACE_GLOBAL_SEQUENCE = HandleTraceSequence(0)

next_trace_global_sequence() =
    @atomic HANDLE_TRACE_GLOBAL_SEQUENCE.x += 1


function trace_locked!(handle::Handle)
    handle.__dbg || return handle
    push!(handle.dbg_trace, HandleEvent(
        handle.uuid,
        next_trace_global_sequence(),
        time_ns(),   #  not consistent across different threads
        iscanceled(handle.cancel_token),
        handle.result,
        handle.error,
        handle.trace,
        @atomic(handle.status),
    ))
    return handle
end

function trace!(handle::Handle)
    handle.__dbg || return handle
    lock(handle.lock) do
        trace_locked!(handle)
    end
    return handle
end


Base.notify(handle::Handle) = notify(handle.cond; all=true, error=false)

function transit_locked!(handle::Handle, status::HandleStatuses.Status; force::Bool=false)
    force || check_transit(HandleStatuses.TRANSITIONS, @atomic(handle.status), status)
    @atomic handle.status = status
    trace_locked!(handle)
    return handle
end

function set_status_locked!(handle::Handle, status::HandleStatuses.Status; force::Bool=false)
    transit_locked!(handle, status; force)
    notify(handle)
    return handle
end

function set_status!(handle::Handle, status::HandleStatuses.Status; force::Bool=false)
    lock(handle.lock) do 
        set_status_locked!(handle, status; force)
    end
    return handle
end

function set_error_locked!(handle::Handle, error, trace::Vector=[]; force::Bool=false)
    handle.error = error
    handle.trace = trace
    set_status_locked!(handle, HandleStatuses.Failed; force)
    return handle
end

function set_error!(handle::Handle, error, trace::Vector=[]; force::Bool=false)
    lock(handle.lock) do
        set_error_locked!(handle, error, trace; force)
    end
    return handle
end

function set_error_force!(handle::Handle, error, trace::Vector=[])
    set_error!(handle, error, trace; force=true)
    return handle
end

function try_pending!(handle::Handle)::Bool
    lock(handle.lock) do
        iscanceled(handle) && return false
        set_status_locked!(handle, HandleStatuses.Pending)
        return true
    end
end

function try_running!(handle::Handle)::Bool
    lock(handle.lock) do
        iscanceled(handle) && return false
        set_status_locked!(handle, HandleStatuses.Running)
        return true
    end
end

function async_execute!(@nospecialize(f), handle::Handle, sem::Semaphore, pool::Symbol)::Nothing
    if ! try_running!(handle)
        release(sem)
        return nothing  # skip canceled
    end
    Threads.@spawn pool begin
        try
            result = try
                Base.invokelatest(f, handle.cancel_token)
            catch ex
                set_error!(handle, ex, catch_backtrace())
                nothing
            end
            lock(handle.lock) do
                if isrunning(handle)
                    handle.result = result
                    set_status_locked!(handle, HandleStatuses.Completed)
                elseif iscancelling(handle)
                    set_status_locked!(handle, HandleStatuses.Canceled)
                elseif isfailed(handle)
                    # pass
                else
                    set_error_force!(handle, ExecutorInternalError(
                        "Unknown handle state",
                    ))
                end
            end
        catch
            set_error_force!(handle, ExecutorInternalError(
                "Unknown error",
            ))
        finally
            release(sem)
        end
    end
    return nothing
end

"""
    cancel!(handle::Handle)::Handle

Job cancellation; job completion by cancel token is a user responsibility.
"""
function cancel!(handle::Handle)
    lock(handle.lock) do
        isfinal(handle) && return handle
        cancel!(handle.cancel_token)
        status = isrunning(handle) ?
            HandleStatuses.Cancelling : # Job task updates its own status from Cancelling to Canceled
            HandleStatuses.Canceled
        set_status_locked!(handle, status)
    end
    return handle
end


struct JobCancelledError <: Exception
    msg :: AbstractString
end

function Base.showerror(io::IO, e::JobCancelledError)
    print(io, "JobCancelledError: ", e.msg)
end

"""
    wait(handle::Handle)::Nothing

Wait job finalize.
"""
function Base.wait(handle::Handle)
    lock(handle.lock) do 
        while ! isfinal(handle)
            wait(handle.cond)
        end
    end
    return nothing
end

"""
    fetch(handle::Handle)::Any

Wait job finalize and fetch result or throw error.
"""
function Base.fetch(handle::Handle)
    wait(handle)
    if iscompleted(handle)
        return handle.result
    end
    if handle.__dbg
        @error "Handle trace" handle.trace
    end
    isfailed(handle) && throw(CapturedException(
        handle.error,
        handle.trace,
    ))
    iscanceled(handle) && throw(JobCancelledError(
        "Job was cancelled",
    ))
    throw(ExecutorInternalError(
        "Something wrong",
    ))
end
