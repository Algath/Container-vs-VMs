#!/usr/bin/env bash
#
# Live demo: Containers vs VMs - cold start, idle memory, disk footprint
# See README.md for prerequisites and full setup.
#
# Usage: ./demo-container-vs-vm.sh
#
# Structured as functions and sourceable (guarded at the bottom): tests/test-container.sh
# sources this file and calls only the container_* functions, so CI exercises the real
# demo code instead of a separate reimplementation of it.

set -euo pipefail

IMAGE="python:3.14-alpine"
VM_NAME="alpine-demo"
VM_DISK="$HOME/vm-demo/alpine.qcow2"
VM_USER="demo"      # dedicated user set up on the VM, never root, see README
VM_IP=""            # empty = auto-detect via virsh domifaddr
VM_SSH_KEY="$HOME/.ssh/vm_demo_key"
PYCMD='print("hello world")'

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

section() {
    echo -e "\n${CYAN}=== $1 ===${NC}"
}

# Force the qemu:///system connection (avoids ambiguity with qemu:///session)
# and English output (the state check below relies on "running").
virsh() { LC_ALL=C command virsh --connect qemu:///system "$@"; }

# ---------------------------------------------------------------------------
# 1. DOCKER CONTAINER
# ---------------------------------------------------------------------------

container_cold_start() {
    start=$(date +%s%N)
    docker run --rm "$IMAGE" python3 -c "$PYCMD"
    end=$(date +%s%N)
    container_start_ms=$(( (end - start) / 1000000 ))
    echo -e "${GREEN}Container time: ${container_start_ms} ms${NC}"
}

container_idle_memory() {
    docker run -d --rm --name demo-mem "$IMAGE" sleep 60 > /dev/null
    sleep 1
    container_mem=$(docker stats --no-stream --format "{{.MemUsage}}" demo-mem)
    echo -e "${GREEN}Container memory: ${container_mem}${NC}"
    docker stop demo-mem > /dev/null
}

container_disk_footprint() {
    container_size=$(docker images "$IMAGE" --format "{{.Size}}")
    echo -e "${GREEN}Container image size: ${container_size}${NC}"
}

run_container_section() {
    section "CONTAINER — cold start"
    container_cold_start
    section "CONTAINER — idle memory"
    container_idle_memory
    section "CONTAINER — disk footprint"
    container_disk_footprint
}

# ---------------------------------------------------------------------------
# 2. VM (libvirt/virsh, already running)
# ---------------------------------------------------------------------------

vm_precheck() {
    vm_state=$(virsh domstate "$VM_NAME")
    if [[ "$vm_state" != "running" ]]; then
        echo "VM '$VM_NAME' is not running (state: $vm_state). Run 'virsh start $VM_NAME' before the demo."
        exit 1
    fi

    if [[ -z "$VM_IP" ]]; then
        VM_IP=$(virsh domifaddr "$VM_NAME" | awk '/ipv4/ {print $4}' | cut -d'/' -f1)
    fi

    if [[ -z "$VM_IP" ]]; then
        echo "Could not detect the VM's IP. Set VM_IP manually in the script."
        exit 1
    fi

    # An array, not a string: keeps each -o flag/value pair as its own argument
    # instead of relying on word-splitting a string (which shellcheck SC2086 flags).
    SSH_OPTS=(-i "$VM_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
}

vm_cold_start() {
    start=$(date +%s%N)
    # PYCMD is a fixed local constant (not external input), so its client-side
    # expansion into the remote command string here is intentional.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "python3 -c '${PYCMD}'"
    end=$(date +%s%N)
    vm_start_ms=$(( (end - start) / 1000000 ))
    echo -e "${YELLOW}VM time (SSH + exec): ${vm_start_ms} ms${NC}"
}

vm_idle_memory() {
    vm_mem=$(ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "free -h | awk '/Mem:/ {print \$3\" / \"\$2}'")
    echo -e "${YELLOW}VM memory used: ${vm_mem}${NC}"
}

vm_disk_footprint() {
    if [[ -f "$VM_DISK" ]]; then
        # qcow2 is a sparse format: allocated size is often smaller than the declared virtual size
        vm_size=$(du -h "$VM_DISK" | cut -f1)
        echo -e "${YELLOW}VM disk size (allocated): ${vm_size}${NC}"
    else
        echo -e "${YELLOW}VM disk not found at ${VM_DISK} — check VM_DISK in the script.${NC}"
        vm_size="?"
    fi
}

run_vm_section() {
    vm_precheck
    section "VM — cold start"
    vm_cold_start
    section "VM — idle memory"
    vm_idle_memory
    section "VM — disk footprint"
    vm_disk_footprint
}

# ---------------------------------------------------------------------------
# 3. SUMMARY
# ---------------------------------------------------------------------------

print_summary() {
    section "SUMMARY"
    printf "%-20s %-15s %-15s\n" "Metric" "Container" "VM"
    printf "%-20s %-15s %-15s\n" "------" "---------" "--"
    printf "%-20s %-15s %-15s\n" "Cold start" "${container_start_ms} ms" "${vm_start_ms} ms"
    printf "%-20s %-15s %-15s\n" "Idle memory" "${container_mem}" "${vm_mem}"
    printf "%-20s %-15s %-15s\n" "Disk footprint" "${container_size}" "${vm_size}"
}

run_all() {
    run_container_section
    run_vm_section
    print_summary
}

# Only run the full demo when executed directly, sourcing this file (as
# tests/test-container.sh does) skips straight to defining the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all
fi
