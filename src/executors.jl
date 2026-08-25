# SPDX-License-Identifier: MIT

module ExecutorStatuses
    @enum Status::UInt8 begin
        Open
        Closed
        Failed
    end
end

mutable struct Executor
    const   lock        :: ReentrantLock
    const   pool        :: Symbol
    const   sem         :: Base.Semaphore
    const   queue       :: Channel{Job}
    dispatcher          :: Union{Nothing, Task}
    error               :: Union{Nothing, Any}
    trace               :: Union{Nothing, Vector}
    @atomic status      :: ExecutorStatuses.Status
end

function Executor(;
    pool         :: Symbol  = :default,
    queue_size   :: Integer = 8,
    concurrently :: Integer = 1,
)
    pool in (:default, :interactive) || throw(ArgumentError(
        "`pool` must be one of (:default, :interactive), got: $(repr(pool))",
    ))
    queue_size > 0 || throw(ArgumentError(
        "`queue_size` must be positive, got $queue_size",
    ))
    concurrently > 0 || throw(ArgumentError(
        "`concurrently` must be positive, got $concurrently",
    ))
    executor = Executor(
        ReentrantLock(),
        pool,
        Semaphore(concurrently),
        Channel{Job}(queue_size),
        nothing,  # dispatcher
        nothing,  # error
        nothing,  # trace
        ExecutorStatuses.Open,
    )
    dispatch!(executor)
    return executor
end

"""
    isopen(executor::Executor)::Bool

Returns `true` if executor is ready to accept jobs.
"""
Base.isopen(executor::Executor)::Bool =
    ExecutorStatuses.Open == @atomic executor.status

"""
    iscrashed(executor::Executor)::Bool

Returns `true` if executor is crashed.
"""
iscrashed(executor::Executor)::Bool =
    ExecutorStatuses.Failed == @atomic executor.status

"""
    isclosed(executor::Executor)::Bool

Returns `true` if executor is closed.
"""
isclosed(executor::Executor)::Bool =
    ExecutorStatuses.Closed == @atomic executor.status


struct ExecutorInternalError <: Exception
    msg :: AbstractString
end

function Base.showerror(io::IO, e::ExecutorInternalError)
    print(io, "ExecutorInternalError: ", e.msg)
end

function dispatch!(executor::Executor)
    lock(executor.lock) do
        executor.dispatcher === nothing || throw(ArgumentError(
            "Executor dispatcher already exists",
        ))
        executor.dispatcher = Threads.@spawn executor.pool begin
            for job in executor.queue 
                try
                    try_pending!(job.handle) || continue  # skip canceled 
                    acquire(executor.sem)
                    async_execute!(job.f, job.handle, executor.sem, executor.pool)  # release here
                catch ex
                    try
                        set_error_force!(job.handle, ExecutorInternalError(
                            "Executor dispatcher error",
                        ))
                        lock(executor.lock) do 
                            close(executor.queue)
                            executor.error = ex
                            executor.trace = catch_backtrace()
                            executor.status = ExecutorStatuses.Failed
                        end
                        for job in executor.queue
                            set_error_force!(job.handle, ExecutorInternalError(
                                "Executor dispatcher error",
                            ))
                        end
                    catch
                        # pass
                    end
                    rethrow()
                end
            end
        end
    end
    return executor
end


"""
    close(executor::Executor)

Stop accepting new jobs; accepted jobs are finalize; jobs completion is a user responsibility.
"""
function Base.close(executor::Executor)
    lock(executor.lock) do
        if isclosed(executor)
            # pass
        elseif isopen(executor)
            close(executor.queue)
            @atomic executor.status = ExecutorStatuses.Closed
        elseif iscrashed(executor)
            throw(CapturedException(executor.error, executor.trace))
        else
            throw(ExecutorInternalError(
                "Unknown error",
            ))
        end
    end
    return executor
end


"""
    execute!(@nospecialize(f), executor::Executor; __dbg::Bool=false)

Synchronous execution; `__dbg` enables `Handle` trace collection and shows it on errors.

# Examples

```julia
julia> result = execute!(executor) do
           2
       end;
2
```
"""
function execute!(@nospecialize(f), executor::Executor; __dbg::Bool=false)
    handle = submit!(f, executor; __dbg)
    result = fetch(handle)
    return result
end

struct ExecutorClosedError <: Exception
    msg :: AbstractString
end

function Base.showerror(io::IO, e::ExecutorClosedError)
    print(io, "ExecutorClosedError: ", e.msg)
end

struct ExecutorRejectedError <: Exception
    msg :: AbstractString
end

function Base.showerror(io::IO, e::ExecutorRejectedError)
    print(io, "ExecutorRejectedError: ", e.msg)
end


"""
    submit!(@nospecialize(f), executor::Executor; __dbg::Bool=false)::Handle

Asynchronous execution; `__dbg` enables `Handle` trace collection and shows it on `Base.fetch(handle)` errors.

# Examples

```julia
julia> handle = submit!(executor) do
           1
       end

julia> fetch(handle)
1
```
"""
function submit!(@nospecialize(f), executor::Executor; __dbg::Bool=false)::Handle
    hasmethod(f, Tuple{CancelToken}) || throw(ArgumentError(
        "submitted  function must accept a `CancelToken`; look submit!() doc and use `do` block.",
    ))
    lock(executor.lock) do
        queue = executor.queue
        iscrashed(executor) && throw(ExecutorInternalError(
            "Executor is failed"
        ))
        isclosed(executor) && throw(ExecutorClosedError(
            "Executor is closed",
        ))
        isfull(queue) && throw(ExecutorRejectedError(
            "Executor queue is full",
        ))
        isopen(queue) || throw(ExecutorInternalError(
            "Unknown error"
        ))
        job = Job(f; __dbg)
        put!(queue, job)
        return job.handle
    end
end
