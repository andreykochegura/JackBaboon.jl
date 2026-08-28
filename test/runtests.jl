# SPDX-License-Identifier: MIT

function run_test_process(file_name; threads)
    cmd = `$(Base.julia_cmd())
    --threads=$threads
    --project=$(Base.active_project())
    $file_name`
    run(pipeline(cmd, stdout=Base.stdout, stderr=Base.stderr); wait=true)
    return nothing
end

run_test_process("base.jl", threads="2,2")
run_test_process("transitions.jl", threads="2,2")

if ! (get(ENV, "JACKBABOON_TEST_PROFILE", "local") == "ci")
    run_test_process("crush.jl", threads="2,2")
    # run_test_process("fuzz.jl", threads="2,2")
    run_test_process("stress.jl", threads="2,2")
    run_test_process("functional.jl", threads="4,4")
end
