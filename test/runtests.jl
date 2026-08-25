using Test
using JackBaboon

function wait_queue(executor)
    while isfull(executor.queue)
        yield()
    end
end

@testset "Smoke" begin
    executor = Executor(
        pool = :default,
        queue_size = 1,
        concurrently = 1,
    )
    @test isopen(executor)

    x, y = "Jack", "Baboon"
    for i = 1 : 5
        completed = submit!(executor) do c
            x
        end
        @test fetch(completed) == x
        wait_queue(executor)
    end
    for i = 1 : 5
        res = execute!(executor) do c
            1
        end
        @test res == 1
    end

    release = Base.Event()
    started = Base.Event()
    running = submit!(executor) do c
        notify(started)
        wait(release)
        x
    end
    wait_queue(executor)
    pending = submit!(executor) do c
        x
    end
    wait_queue(executor)
    queued = submit!(executor) do c
        x
    end
    wait(started)
    @test isrunning(running)
    @test ispending(pending)
    @test isqueued(queued)
    @test_throws ExecutorRejectedError submit!(executor) do c
        x
    end
    notify(release)
    wait(queued)
    @test iscompleted(running)
    @test iscompleted(pending)
    @test iscompleted(queued)
    @test fetch(running) == fetch(pending) == fetch(queued)
    
    failed = submit!(executor) do c
        error()
    end
    wait(failed)
    @test isfailed(failed)
    @test_throws CapturedException fetch(failed)

    release = Base.Event()
    started = Base.Event()
    blocker = submit!(executor) do c
        notify(started)
        wait(release)
        x
    end
    wait_queue(executor)
    pending = submit!(executor) do c
        iscanceled(c) ? x : y
    end
    wait_queue(executor)
    queued = submit!(executor) do c
        x
    end
    wait(started)
    cancel!(blocker)
    @test iscancelling(blocker)
    cancel!(pending)
    cancel!(queued)
    notify(release)
    wait(blocker)
    wait(pending)
    wait(queued)
    @test iscanceled(blocker)
    @test iscanceled(pending)
    @test iscanceled(queued)
    @test_throws JobCancelledError fetch(blocker)
    @test_throws JobCancelledError fetch(pending)
    @test_throws JobCancelledError fetch(queued)

    release = Base.Event()
    started = Base.Event()
    after_shotdown = submit!(executor) do c
        notify(started)
        wait(release)
        x
    end
    close(executor)
    @test isclosed(executor)
    wait(started)
    @test isrunning(after_shotdown)
    notify(release)
    wait(after_shotdown)
    @test iscompleted(after_shotdown)
    @test isclosed(executor)
    @test fetch(after_shotdown) == x
end
