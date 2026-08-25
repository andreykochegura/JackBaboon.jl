JackBaboon.jl
=============

[![Build Status](https://github.com/JuliaCI/Coverage.jl/workflows/CI/badge.svg)](https://github.com/JuliaCI/Coverage.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![Tests](https://github.com/OWNER/JackBaboon/actions/workflows/CI.yml/badge.svg)](https://github.com/OWNER/JackBaboon/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/OWNER/JackBaboon/branch/main/graph/badge.svg)](https://codecov.io/gh/OWNER/JackBaboon)
[![Docs](https://img.shields.io/badge/docs-stable-blue)](https://OWNER.github.io/JackBaboon/)

Task executor with limited concurrency for Julia.

### Fast Start

```julia
executor = Executor(pool = :default, queue_size=4, concurrently=2)

# Asynchronous execution:

handle = submit!(executor) do cancel
    do_work(cancel)
end

fetch(handle)

# Synchronous execution:

result = execute!(executor) do cancel
    do_work(cancel)
end
```

### Job States

```mermaid
flowchart LR
    Queued --> Pending
    Queued --> Canceled

    Pending --> Running
    Pending --> Canceled

    Cancelling --> Canceled
    Cancelling --> Failed

    Running --> Completed
    Running --> Cancelling
    Running --> Failed
```

### License

MIT — see [LICENSE](LICENSE).
