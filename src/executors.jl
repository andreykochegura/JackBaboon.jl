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
struct ExecutorInternalError <: Exception  # TuberculosisError
    msg :: AbstractString
    ex  :: Union{Nothing, CapturedException}

    ExecutorInternalError(msg) = new(msg, nothing)
    ExecutorInternalError(msg, ex, bt) = new(msg, CapturedException(ex, bt))
end

function Base.showerror(io::IO, ex::ExecutorInternalError)
    print(io, "ExecutorInternalError: ", ex.msg)
    ex.ex === nothing && return
    print(io, "\nCaused by: ")
    showerror(io, ex.ex.ex, ex.ex.processed_bt)
end



"""
    Executor(;
        pool         :: Symbol  = :default,
        capacity   :: Integer = 8,
        concurrently :: Integer = 1,
    )

Create and run executor with limited concurrency.

# Arguments

- `pool`: thread pool; supported: `:default`, `:interactive`.
- `capacity`: maximum number of queued jobs; new jobs are rejected when queue is full.
- `concurrently`: maximum number of jobs executing concurrently.
"""
mutable struct Executor
    const   lock         :: ReentrantLock
    const   pool         :: Symbol
    const   capacity     :: Int
    const   concurrently :: Int
    const   sem          :: Base.Semaphore
    const   queue        :: Channel{Job}
    const   errors       :: Vector{ExecutorInternalError}
    @atomic state        :: ExecutorStates.State
    dispatcher           :: Union{Nothing, Task}
end

function Base.show(io::IO, ::MIME"text/plain", e::Executor)
    state = @atomic e.state
    print(io, "Executor(;")
    printstyled(io, " #=", state, "=# "; color=:light_black)
    print(io, "pool=", repr(e.pool), ", ")
    print(io, "capacity=", e.capacity, ", ")
    print(io, "concurrently=", e.concurrently, ")")
end

function Executor(;
    pool         :: Symbol  = :default,
    capacity     :: Integer = 8,
    concurrently :: Integer = 1,
)
    pool in (:default, :interactive) || throw(ArgumentError(
        "`pool` must be `:default` or `:interactive`, got: $(repr(pool))",
    ))
    capacity > 0 || throw(ArgumentError(
        "`capacity` must be positive, got $capacity",
    ))
    concurrently > 0 || throw(ArgumentError(
        "`concurrently` must be positive, got $concurrently",
    ))
    executor = Executor(
        ReentrantLock(),
        pool,
        capacity,
        concurrently,
        Semaphore(concurrently),
        Channel{Job}(capacity),
        ExecutorInternalError[],
        ExecutorStates.Open,
        nothing,  # dispatcher
    )
    dispatch!(executor)
    return executor
end


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
                    try_pending!(job.handle) || continue  # skip canceled 
                    acquire(executor.sem)
                    async_execute!(job.f, job.handle, executor.sem, executor.pool)  # release(sem) here
                catch dispatch_ex
                    try_cleanup!(executor, job, dispatch_ex)
                    throw(ExecutorInternalError(
                        "Executor dispatch error; see `executor.errors`",
                    ))
                end
            end
        end
    end
    return executor
end
# in catch block
function try_cleanup!(executor::Executor, job, dispatch_ex)
    lock(executor.lock) do
        try
            close(executor.queue)
            @atomic executor.state = ExecutorStates.Failed
            dispatch_err = ExecutorInternalError("Executor dispatch error", dispatch_ex, catch_backtrace())
            push!(executor.errors, dispatch_err)
            set_error_force!(job.handle, dispatch_err)
            for job in executor.queue
                set_error_force!(job.handle, dispatch_err)
            end
        catch cleanup_ex
            cleanup_err = ExecutorInternalError("Executor cleanup error", cleanup_ex, catch_backtrace())
            push!(executor.errors, cleanup_err)
        end
    end 
end


"""
    close(executor::Executor)::Executor

Graceful shutdown; immediately stop accepting new jobs; accepted jobs are finalize.
"""
function Base.close(executor::Executor)
    lock(executor.lock) do
        if isclosed(executor)
            #pass
        elseif isopen(executor)
            close(executor.queue)
            @atomic executor.state = ExecutorStates.Closed
        elseif iscrashed(executor)
            throw_error(executor)
        else
            throw(ExecutorInternalError(
                "Wrong executor state: `$(@atomic(executor.state))`",
            ))
        end
    end
    return executor
end

function throw_error(executor::Executor)
    length(executor.errors) == 1 ?
        throw(only(executor.errors)) :
        throw(CompositeException(executor.errors))
end


#Future
#terminate!(::Executor)


function with_executor(
    @nospecialize(f),
    ;
    pool         :: Symbol  = :default,
    capacity     :: Integer = 8,
    concurrently :: Integer = 1,
)
    executor = Executor(; pool, capacity, concurrently)
    try
        f(executor)
    finally
        close(executor)
    end
end



"""
    execute!(@nospecialize(f), executor::Executor)

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
    submit!(@nospecialize(f), executor::Executor)::Handle

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
        iscrashed(executor) && throw_error(executor)
        istaskfailed(executor.dispatcher) && throw(ExecutorInternalError(
            "Executor dispatcher unexpected crash; see `executor.dispatcher`", 
        ))
        isfull(queue) && throw(ExecutorRejectedError(
            "Executor queue is full",
        ))
        isopen(queue) || throw(ExecutorInternalError(
            "Executor queue is closed; executor state: `$(@atomic(executor.state))`",
        ))
        job = Job(f)
        put!(queue, job)
        return job.handle
    end
end
