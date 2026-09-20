#!/usr/bin/env bash
#
# Automated tests for the container side of the demo. Sources demo-container-vs-vm.sh
# and calls only its container_* functions — this exercises the actual demo code
# (not a separate reimplementation of it), just skipping the VM section.
#
# Run manually with ./tests/test-container.sh, or via CI (see .github/workflows/ci.yml).
# The VM side is NOT covered here — see README.md's CI section for why, and
# tests/test-vm.sh for the local equivalent that does cover it.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=demo-container-vs-vm.sh
source ./demo-container-vs-vm.sh

echo "== Test 1: container runs the job and prints the expected output =="
output=$(docker run --rm "$IMAGE" python3 -c "$PYCMD")
if [[ "$output" != "hello world" ]]; then
    echo "FAIL: expected 'hello world', got '${output}'"
    exit 1
fi
echo "OK"

echo "== Test 2: container_cold_start() runs without error and sets a timing =="
container_cold_start
if [[ -z "${container_start_ms:-}" ]]; then
    echo "FAIL: container_start_ms was not set"
    exit 1
fi
echo "OK (${container_start_ms} ms)"

echo "== Test 3: container_disk_footprint() reports a readable image size =="
container_disk_footprint
if [[ -z "${container_size:-}" ]]; then
    echo "FAIL: container_size was not set"
    exit 1
fi
echo "OK (${container_size})"

echo "== Test 4: SSH-enabled container builds and accepts key-based login =="

docker build -t python-ssh-demo -f Dockerfile.ssh-demo .
docker run -d --rm -p 2222:22 --name ssh-demo-ci python-ssh-demo > /dev/null

cleanup() { docker stop ssh-demo-ci > /dev/null 2>&1 || true; }
trap cleanup EXIT

# Wait for sshd to accept connections (a fresh container needs a moment to start it)
for _ in $(seq 1 10); do
    if (exec 3<>/dev/tcp/localhost/2222) 2>/dev/null; then
        exec 3<&- 3>&-
        break
    fi
    sleep 1
done

# Generate a throwaway key and install it directly (standing in for the
# interactive ssh-copy-id step from the README, which needs a password prompt
# that CI can't answer). Clear out any leftover key from a previous local run
# first — otherwise ssh-keygen prompts to overwrite, which would hang non-
# interactively in CI instead of just failing.
rm -f /tmp/ci_key /tmp/ci_key.pub
ssh-keygen -t ed25519 -N "" -f /tmp/ci_key -q
docker exec ssh-demo-ci mkdir -p /home/demo/.ssh
docker cp /tmp/ci_key.pub ssh-demo-ci:/home/demo/.ssh/authorized_keys
docker exec ssh-demo-ci chown -R demo:demo /home/demo/.ssh
docker exec ssh-demo-ci chmod 700 /home/demo/.ssh
docker exec ssh-demo-ci chmod 600 /home/demo/.ssh/authorized_keys

whoami_result=$(ssh -i /tmp/ci_key -p 2222 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    demo@localhost whoami)

if [[ "$whoami_result" != "demo" ]]; then
    echo "FAIL: SSH login did not return the expected user (got '${whoami_result}')"
    exit 1
fi
echo "OK"

echo
echo "All container-side tests passed."
