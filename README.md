[![CI](https://github.com/andreykochegura/JackBaboon/actions/workflows/CI.yml/badge.svg)](https://github.com/andreykochegura/JackBaboon/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/andreykochegura/JackBaboon.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/andreykochegura/JackBaboon.jl)
[![Docs](https://img.shields.io/badge/docs-stable-blue)](https://andreykochegura.github.io/JackBaboon.jl/)
[![Julia](https://img.shields.io/badge/Julia-%E2%89%A51.10-purple)](https://julialang.org/)
[![Status](https://img.shields.io/badge/status-alpha-orange.svg)](https://github.com/andreykochegura/JackBaboon.jl)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

*One day, a Python service, exhausted by CPU-bound load, decided to shift some of it to a Julia microservice and breathed a sigh of relief. Countless overjoyed service users launched countless Python coroutines, and those launched countless Julia tasks... And then the baboon and his legless master came to the rescue!*

# JackBaboon.jl

A production-oriented Julia executor:

- Bounded queue with controlled concurrency and backpressure.
- Synchronous and asynchronous job execution.
- Cooperative job cancellation.
- Explicit job state machine.
- Graceful shutdown.
- Isolated job failures.

![Jack&James.jpg](images/Jack&James.jpg)

## Fast Start

### Install

```julia-repl
julia>] add https://github.com/andreykochegura/JackBaboon.jl
```

### Example

```julia-repl
julia> using JackBaboon

julia> executor = Executor(
           pool           = :default,
           queue_capacity = 8,
           concurrently   = 2,
       );

julia> result = execute!(executor) do cancel_token
           "Job complited"
       end
"Job complited"

julia> handle = submit!(executor) do cancel_token
           while ! iscancelrequested(cancel_token)
               sleep(0.1)
           end
           iscancelrequested(cancel_token) ? "Job stoped" : "Job complited"
       end;

julia> stop!(handle);

julia> fetch(handle)
"Job stoped"
```

![Jack&James2.jpg](images/Jack&James2.jpg)

## Execution Model

### Capacity & Backpressure

* The `Executor` maintains a bounded queue of accepted jobs..
* The executor queue is bounded by `queue_capacity`.
* When the **queue** reaches `queue_capacity`, new jobs are rejected with `ExecutorRejectedError`.
* The number of concurrently executing jobs is bounded by `concurrently`.
* A job becomes `Pending` before acquiring an execution slot.

### Why without workers?

A task is created for each running job. Persistent worker tasks are intentionally not used:

* Worker tasks may become thread-affine and reduce scheduling flexibility.
* Worker tasks may retain unintended task-local execution context between jobs.
* Worker tasks may fail, stall, or become a source of cascading failures.

### Job Lifecycle

Each accepted job follows a lifecycle represented by a state machine diagram.

- `Queued`: the job has been accepted and is waiting in the executor queue.
- `Pending`: the job has been admitted by the dispatcher and is waiting for an execution slot.
- `Running`: the job is executing.
- `Stopping`: cancellation has been requested for a running job; job completion is the user's responsibility.
- `Stopped`: a `Running` job completed after a cancellation request.
- `Canceled`: a `Queued` or `Pending` job was canceled before it became `Running`.
- `Completed`: the job completed successfully.
- `Failed`: the job terminated due to a job error or an executor dispatcher error.

### State Machine Diagram

```mermaid
    stateDiagram-v2
    classDef queued fill:#4063D8
    classDef pending fill:#4063D8
    classDef running fill:#4063D8
    classDef completed fill:#389826
    classDef failed fill:#CB3C33
    classDef stopping fill:#9558B2
    classDef stopped fill:#9558B2
    classDef canceled fill:grey

    class Queued queued
    class Pending pending
    class Running running
    class Completed completed
    class Failed failed
    class Stopping stopping
    class Stopped stopped
    class Canceled canceled

    [*] --> Queued: submit!() or execute!()
    Queued --> Pending: taken from queue
    Queued --> Canceled: stop!()
    Pending --> Running: placed into execution slot
    Pending --> Canceled: stop!()
    Running --> Stopping: stop!()
    Running --> Failed: job error or executor failure
    Running --> Completed: job completed
    Stopping --> Stopped: job completed
    Stopping --> Failed: job error or executor failure
    Stopped --> [*]
    Canceled --> [*]
    Completed --> [*]
    Failed --> [*]
```


## Planned

- Metrics.
- Priorities.
- Pause and resume.
- Diagnostic warnings.

![Jack&James3.jpg](images/Jack&James3.jpg)

## P.S.

Hopefully, the brave baboon will help you to protect your critical Julia tasks.
