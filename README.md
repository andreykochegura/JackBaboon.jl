[![Tests](https://github.com/andreykochegura/JackBaboon/actions/workflows/CI.yml/badge.svg)](https://github.com/andreykochegura/JackBaboon/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/andreykochegura/JackBaboon/branch/master/graph/badge.svg)](https://codecov.io/gh/andreykochegura/JackBaboon)
[![Docs](https://img.shields.io/badge/docs-stable-blue)](https://andreykochegura.github.io/JackBaboon/)
[![Julia](https://img.shields.io/badge/Julia-%E2%89%A51.10-purple)](https://julialang.org/)
[![Status](https://img.shields.io/badge/status-alpha-orange.svg)](https://github.com/andreykochegura/JackBaboon)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

# JackBaboon.jl

*One day, a Python service, exhausted by CPU-bound load, decided to shift some of it to a Julia microservice and breathed a sigh of relief. Countless overjoyed service users launched countless Python coroutines, and those launched countless Julia tasks... And then JackBaboon and his legless master came to the rescue!*

<div style="display:flex; align-items:center; gap:24px;">
<div style="flex:1; min-width:0;">
JackBaboon is a production-oriented Julia executor:

- Bounded job queue, concurrency and rejection.
- Synchronous and asynchronous thread-pool execution.
- Cooperative job cancellation.
- Explicit job state machine.
- Graceful <!-- and immediate. -->shutdown.
- Fail-safe execution.
</div>
<div style="flex:0 1 320px; min-width:350px;">
<img src="images/Jack&amp;James.jpg" alt="Jack & James" style="display:block; width:100%; height:auto;">
</div>
</div>

## Install

```julia-repl
julia>] add https://github.com/andreykochegura/JackBaboon.jl
```

## Fast Start

<div style="display:flex; align-items:center; gap:24px;">
<div style="flex:1; min-width:0;">

```julia-repl
julia> using JackBaboon

julia> executor = Executor();

julia> result = execute!(executor) do cancel_token
           do_work()
       end;
```
</div>
<div style="flex:0 1 320px; min-width:350px;">
<img src="images/Jack&amp;James2.jpg" alt="Jack & James" style="display:block; width:100%; height:auto;">
</div>
</div>

## Execution Model

A task is created for each running job. Worker-tasks are intentionally not used:

* A worker may become thread-affine and introduce unpredictable delays.
* A worker may retain contaminated or unexpected execution context.
* A worker may fail, stall, or become a source of cascading failures.

#### State Machine Diagram

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

    [*] --> Queued
    Queued --> Pending
    Queued --> Canceled
    Pending --> Running
    Pending --> Canceled
    Running --> Stopping
    Running --> Failed
    Running --> Completed
    Stopping --> Stopped
    Stopping --> Failed
    Stopped --> [*]
    Canceled --> [*]
    Completed --> [*]
    Failed --> [*]
```

## Future

<div style="display:flex; align-items:center; gap:24px;">
<div style="flex:1; min-width:0;">

- immediate shutdown
- detailed examples
- benchmarks
- metrics
- prioritet
- pause and resume
- etc.

</div>
<div style="flex:0 1 320px; min-width:350px;">
<img src="images/Jack&amp;James3.jpg" alt="Jack & James" style="display:block; width:100%; height:auto;">
</div>
</div>

## P.S.

Hopefully, the brave baboon will help you to protect your critical Julia tasks.
