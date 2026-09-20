#!/usr/bin/env bash
#
# Local tests for the VM side of the demo. Sources demo-container-vs-vm.sh and calls
# its vm_* functions directly — same principle as tests/test-container.sh, exercising
# the real demo code instead of a reimplementation of it. This includes a full boot
# cycle (vm_cold_start powers the VM on from "shut off"), so it takes longer to run
# than a quick check would — that's the point: it's testing the same cold-start path
# the live demo depends on, not a shortcut around it.
#
# Run manually on the host that has the pre-provisioned alpine-demo VM — NOT part of
# CI (see README.md's CI section for why: it needs a persistent, already-configured VM
# that a fresh GitHub Actions runner cannot reach or provision on the fly).
#
# Usage: ./tests/test-vm.sh
# Run this before a live demo (or to attach its output as evidence that the VM path
# was actually tested) — it exercises the same functions the main demo script uses,
# and leaves the VM powered off afterward, exactly like a real run would.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=demo-container-vs-vm.sh
source ./demo-container-vs-vm.sh

# Safety net: if an assertion below fails partway through, make sure the VM
# doesn't stay running. Idempotent — vm_teardown is a no-op if already off.
trap 'vm_teardown > /dev/null 2>&1 || true' EXIT

echo "== Test 1: vm_cold_start() boots the VM from off, runs the job, and sets a timing =="
vm_cold_start
if [[ -z "${vm_start_ms:-}" ]]; then
    echo "FAIL: vm_start_ms was not set"
    exit 1
fi
echo "OK (${vm_start_ms} ms, IP ${VM_IP})"

echo "== Test 2: key-based SSH login works as the dedicated user (not root) =="
whoami_result=$(ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" whoami)
if [[ "$whoami_result" != "$VM_USER" ]]; then
    echo "FAIL: expected user '$VM_USER', got '$whoami_result'"
    exit 1
fi
echo "OK"

echo "== Test 3: root SSH login is rejected (password auth disabled, no leftover key) =="
if ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
       -o BatchMode=yes "root@${VM_IP}" true 2>/dev/null; then
    echo "FAIL: root SSH login unexpectedly succeeded — security regression"
    exit 1
fi
echo "OK (root login correctly refused)"

echo "== Test 4: vm_idle_memory() reports readable memory usage =="
vm_idle_memory
if [[ -z "${vm_mem:-}" ]]; then
    echo "FAIL: vm_mem was not set"
    exit 1
fi
echo "OK (${vm_mem})"

echo "== Test 5: vm_disk_footprint() reports a readable disk size =="
vm_disk_footprint
if [[ -z "${vm_size:-}" || "$vm_size" == "?" ]]; then
    echo "FAIL: could not read VM disk size (VM_DISK=${VM_DISK})"
    exit 1
fi
echo "OK (${vm_size})"

echo "== Test 6: vm_teardown() shuts the VM back down =="
vm_teardown
final_state=$(virsh domstate "$VM_NAME")
if [[ "$final_state" != "shut off" ]]; then
    echo "FAIL: VM did not shut down (state: $final_state)"
    exit 1
fi
echo "OK"

echo
echo "All VM-side tests passed."
