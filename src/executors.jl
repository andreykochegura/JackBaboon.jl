# SPDX-License-Identifier: MIT

module ExecutorStates
    @enum State::UInt8 begin
        Open
        Closed
        Failed
    end
end


"""
    ExecutorInternalError(msg::AbstractString)

Thrown on an internal executor error.
"""
struct ExecutorInternalError <: Exception
    msg :: AbstractString
    ex  :: Union{Nothing, CapturedException}

    ExecutorInternalError(msg) = new(msg, nothing)
    ExecutorInternalError(msg, ex, bt) = new(msg, CapturedException(ex, bt))
end

function Base.showerror(io::IO, ex::ExecutorInternalError)
    print(io, "ExecutorInternalError: ", ex.msg)
    if ex.ex !== nothing
        print(io, "\nCaused by: ")
        showerror(io, ex.ex.ex, ex.ex.processed_bt)
    end
end


"""
Executor(;
    pool           :: Symbol  = :default,
    queue_capacity :: Integer = 8,
    concurrently   :: Integer = 1,
)

Create and run an executor with limited concurrency.

# Arguments

|       Name       | DataType  |   Default  |                                Description                                   |
| :--------------- | :-------- | :--------- | :--------------------------------------------------------------------------- |
| `pool`           | `Symbol`  | `:default` | Thread pool; supported values are `:default` and `:interactive`.             |
| `queue_capacity` | `Integer` | `8`        | Maximum number of queued jobs. New jobs are rejected when the queue is full. |
| `concurrently`   | `Integer` | `1`        | Maximum number of jobs executing concurrently.                               |
"""
mutable struct Executor
    const lock           :: ReentrantLock
    const pool           :: Symbol
    const queue_capacity :: Int
    const concurrently   :: Int
    const sem            :: Base.Semaphore
    const queue          :: Channel{Job}
    const metrics        :: Metrics
    error                :: Union{Nothing, Exception}
    dispatcher           :: Union{Nothing, Task}
    @atomic state        :: ExecutorStates.State
end

function Base.show(io::IO, ::MIME"text/plain", e::Executor)
    state = @atomic e.state
    print(io, "Executor(;")
    printstyled(io, " #=", state, "=# "; color=:light_black)
    print(io, "pool=", repr(e.pool), ", ")
    print(io, "queue_capacity=", e.queue_capacity, ", ")
    print(io, "concurrently=", e.concurrently, ")")
end

function Executor(;
    pool           :: Symbol  = :default,
    queue_capacity :: Integer = 8,
    concurrently   :: Integer = 1,
)
    pool in (:default, :interactive) || throw(ArgumentError(
        "`pool` must be `:default` or `:interactive`, got: $(repr(pool))",
    ))
    queue_capacity > 0 || throw(ArgumentError(
        "`queue_capacity` must be positive, got $queue_capacity",
    ))
    concurrently > 0 || throw(ArgumentError(
        "`concurrently` must be positive, got $concurrently",
    ))
    executor = Executor(
        ReentrantLock(),
        pool,
        queue_capacity,
        concurrently,
        Semaphore(concurrently),
        Channel{Job}(queue_capacity),
        Metrics(),
        nothing,
        nothing,  # dispatcher
        ExecutorStates.Open,
    )
    dispatch!(executor)
    return executor
end


"""
metrics(executor::Executor)::NamedTuple

Returns a metrics snapshot. Metrics are **eventually consistent**.

# Metrics

|    Name     | DataType |    Type     |                          Description                                 |
| :---------- | :------- | :---------- | :------------------------------------------------------------------- |
| `rejected`  |   Int    | **Counter** | Total number of tasks rejected                                       |
| `queued`    |   Int    | **Counter** | Total number of tasks accepted                                       |
| `started`   |   Int    | **Counter** | Total number of tasks started                                        |
| `completed` |   Int    | **Counter** | Total number of tasks completed successfully                         |
| `stopped`   |   Int    | **Counter** | Total number of tasks stopped after `stop!`                          |
| `cancelled` |   Int    | **Counter** | Total number of tasks cancelled before execution                     |
| `failed`    |   Int    | **Counter** | Total number of tasks that failed due to an error in the task itself |
| `backlog`   |   Int    | **Gauge**   | Current number of tasks in the channel                               |
| `active`    |   Int    | **Gauge**   | Current number of tasks being executed                               |
"""
metrics(e::Executor)::NamedTuple = snapshot(e.metrics)


"""
    isopen(executor::Executor)::Bool

Returns `true` if executor is ready to accept jobs.
"""
Base.isopen(executor::Executor)::Bool =
    ExecutorStates.Open == @atomic executor.state


"""
    iscrashed(executor::Executor)::Bool

Returns `true` if executor is crashed.
"""
iscrashed(executor::Executor)::Bool =
    ExecutorStates.Failed == @atomic executor.state


"""
    isclosed(executor::Executor)::Bool

Returns `true` if executor is closed.
"""
isclosed(executor::Executor)::Bool =
    ExecutorStates.Closed == @atomic executor.state


function dispatch!(executor::Executor)
    lock(executor.lock) do
        executor.dispatcher === nothing || throw(ArgumentError(
            "Executor dispatcher already exists",
        ))
        executor.dispatcher = Threads.@spawn executor.pool begin
            for job in executor.queue 
                try
                    @atomic executor.metrics.backlog -= 1
                    if ! try_pending!(job.handle)
                        @atomic executor.metrics.cancelled += 1
                        continue  # skip canceled 
                    end
                    acquire(executor.sem)
                    @atomic executor.metrics.active += 1
                    if ! try_running!(job.handle)
                        release(executor.sem)
                        @atomic executor.metrics.cancelled += 1
                        continue  # skip canceled
                    end
                    @atomic executor.metrics.started += 1
                    async_execute!(job.f, job.handle, executor.sem, executor.pool, executor.metrics)  # release(sem) here
                catch ex
                    err = ExecutorInternalError("Executor dispatcher error", ex, catch_backtrace())
                    lock(executor.lock) do
                        close(executor.queue)
                        @atomic executor.state = ExecutorStates.Failed
                        executor.error = err
                    end
                    try_failed!(job.handle, err)
                    for job in executor.queue
                        try_failed!(job.handle, err)
                    end
                    rethrow()
                end
            end
        end
    end
    return executor
end


"""
    close(executor::Executor)::Executor

Graceful shutdown; immediately stop accepting new jobs; accepted jobs are finalize asynchronously but executor does not wait.
"""
function Base.close(executor::Executor)
    lock(executor.lock) do
        if isclosed(executor)
            #pass
        elseif isopen(executor)
            close(executor.queue)
            @atomic executor.state = ExecutorStates.Closed
        elseif iscrashed(executor)
            throw(executor.error)
        else
            throw(ExecutorInternalError(
                "Wrong executor state: `$(@atomic(executor.state))`",
            ))
        end
    end
    return executor
end


function with_executor(
    @nospecialize(f),
    ;
    pool         :: Symbol  = :default,
    queue_capacity     :: Integer = 8,
    concurrently :: Integer = 1,
)
    executor = Executor(; pool, queue_capacity, concurrently)
    try
        f(executor)
    finally
        close(executor)
    end
end



"""
    execute!(f, executor::Executor)

Synchronous concurrently execution.

# Examples

```julia-repl
julia> result = execute!(executor) do cancel_token
           do_work()
       end;

julia> result = execute!(executor) do cancel_token
           error("Job error")
       end;
ERROR: Job error
Stacktrace:
 [1] error()
 ...
```
"""
function execute!(@nospecialize(f), executor::Executor)
    handle = submit!(f, executor)
    result = fetch(handle)
    return result
end


"""
    ExecutorClosedError(msg::AbstractString)

Thrown on a job submitting to a closed executor.
"""
struct ExecutorClosedError <: Exception
    msg :: AbstractString
end

function Base.showerror(io::IO, e::ExecutorClosedError)
    print(io, "ExecutorClosedError: ", e.msg)
end


"""
    ExecutorRejectedError(msg::AbstractString)

Thrown on a job submitting to an executor with a full queue.
"""
struct ExecutorRejectedError <: Exception
    msg :: AbstractString
end

function Base.showerror(io::IO, e::ExecutorRejectedError)
    print(io, "ExecutorRejectedError: ", e.msg)
end


"""
    submit!(f, executor::Executor)::Handle

Asynchronous concurrently execution.

# Examples

```julia-repl
julia> handle = submit!(executor) do cancel_token
           do_work()
       end;

julia> result = fetch(handle);

julia> handle = submit!(executor) do cancel_token
           error("Job error")
       end;

julia> fetch(handle)
ERROR: Job error
Stacktrace:
 [1] error(s::String)
 ...
```
"""
function submit!(@nospecialize(f), executor::Executor)::Handle
    hasmethod(f, Tuple{CancelToken}) || throw(MethodError(f, (CancelToken,)))
    lock(executor.lock) do
        queue = executor.queue
        isclosed(executor) && throw(ExecutorClosedError(
            "Executor is closed",
            ))
        iscrashed(executor) && throw(executor.error)
        istaskfailed(executor.dispatcher) && throw(ExecutorInternalError(
            "Executor dispatcher unexpected crash; see `executor.dispatcher`", 
        ))
        if isfull(queue)
            @atomic executor.metrics.rejected += 1
            throw(ExecutorRejectedError("Executor queue is full"))
        end
        isopen(queue) || throw(ExecutorInternalError(
            "Executor queue is closed; executor state: `$(@atomic(executor.state))`",
        ))
        job = Job(f)
        put!(queue, job)
        @atomic executor.metrics.backlog += 1
        @atomic executor.metrics.queued += 1
        return job.handle
    end
end
