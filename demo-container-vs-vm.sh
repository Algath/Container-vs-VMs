#!/usr/bin/env bash
#
# Live demo: Containers vs VMs — cold start, idle memory, disk footprint
# See README.md for prerequisites and full setup.
#
# Usage: ./demo-container-vs-vm.sh
#
# Structured as functions and sourceable (guarded at the bottom): tests/test-container.sh
# and tests/test-vm.sh source this file and call only the functions they need, so tests
# exercise the real demo code instead of a separate reimplementation of it.

set -euo pipefail

IMAGE="python:3.14-alpine"
VM_NAME="alpine-demo"
VM_DISK="$HOME/vm-demo/alpine.qcow2"
VM_USER="demo"      # dedicated user set up on the VM — never root, see README
VM_IP=""            # empty = auto-detect via virsh domifaddr, once the VM is up
VM_SSH_KEY="$HOME/.ssh/vm_demo_key"
PYCMD='print("hello world")'

# How long we're willing to wait for the VM to reach a usable state
BOOT_IP_TIMEOUT=30       # seconds waiting for domifaddr to report an IP
BOOT_SSH_TIMEOUT=30      # seconds waiting for sshd to accept connections
SHUTDOWN_TIMEOUT=20      # seconds waiting for a graceful shutdown before we force it

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

section() {
    echo -e "\n${CYAN}=== $1 ===${NC}"
}

# Force the qemu:///system connection (avoids ambiguity with qemu:///session)
# and English output (state checks below rely on "running" / "shut off").
virsh() { LC_ALL=C command virsh --connect qemu:///system "$@"; }

# An array, not a string: keeps each -o flag/value pair as its own argument
# instead of relying on word-splitting a string (which shellcheck SC2086 flags).
SSH_OPTS=(-i "$VM_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

# ---------------------------------------------------------------------------
# Unit normalization — docker stats (binary/IEC) and docker images (decimal)
# don't agree on a base, and busybox's free/du drop the "i" from binary units.
# Everything gets converted to a byte count first, then formatted the same
# way, so the four metrics are on a genuinely comparable scale.
# ---------------------------------------------------------------------------

bytes_to_mib() {
    awk -v b="$1" 'BEGIN { printf "%.1f MiB", b / 1048576 }'
}

# Parses a docker stats MemUsage figure like "380KiB" or "14.42GiB" into bytes.
parse_docker_size_to_bytes() {
    local value="$1" num unit
    num=$(echo "$value" | sed -E 's/^([0-9.]+).*/\1/')
    unit=$(echo "$value" | sed -E 's/^[0-9.]+//')
    case "$unit" in
        B)   awk -v n="$num" 'BEGIN { printf "%.0f", n }' ;;
        KiB) awk -v n="$num" 'BEGIN { printf "%.0f", n*1024 }' ;;
        MiB) awk -v n="$num" 'BEGIN { printf "%.0f", n*1024*1024 }' ;;
        GiB) awk -v n="$num" 'BEGIN { printf "%.0f", n*1024*1024*1024 }' ;;
        *)   echo 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. DOCKER CONTAINER
# ---------------------------------------------------------------------------

container_cold_start() {
    start=$(date +%s%N)
    docker run --rm "$IMAGE" python3 -c "$PYCMD"
    end=$(date +%s%N)
    container_start_ms=$(( (end - start) / 1000000 ))
    echo -e "${GREEN}Container time (full lifecycle, --rm): ${container_start_ms} ms${NC}"
}

container_idle_memory() {
    docker run -d --rm --name demo-mem "$IMAGE" sleep 60 > /dev/null
    sleep 1
    local raw used_raw used_bytes
    raw=$(docker stats --no-stream --format "{{.MemUsage}}" demo-mem)   # e.g. "380KiB / 14.42GiB"
    used_raw=$(echo "$raw" | cut -d'/' -f1 | xargs)
    used_bytes=$(parse_docker_size_to_bytes "$used_raw")
    container_mem=$(bytes_to_mib "$used_bytes")
    echo -e "${GREEN}Container memory: ${container_mem}${NC}"
    docker stop demo-mem > /dev/null
}

container_disk_footprint() {
    local bytes
    bytes=$(docker image inspect "$IMAGE" --format='{{.Size}}')
    container_size=$(bytes_to_mib "$bytes")
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
# 2. VM (libvirt/virsh) — full boot, then teardown, mirroring `docker run --rm`
# ---------------------------------------------------------------------------

# Waits until `virsh domstate` reports "shut off", forcing it past SHUTDOWN_TIMEOUT.
vm_ensure_off() {
    local state
    state=$(virsh domstate "$VM_NAME")
    if [[ "$state" == "shut off" ]]; then
        return
    fi

    echo "VM '$VM_NAME' is '$state' — shutting it down before the cold-start measurement..."
    virsh shutdown "$VM_NAME" > /dev/null || true

    local waited=0
    while [[ "$(virsh domstate "$VM_NAME")" != "shut off" && $waited -lt $SHUTDOWN_TIMEOUT ]]; do
        sleep 1
        waited=$((waited + 1))
    done

    if [[ "$(virsh domstate "$VM_NAME")" != "shut off" ]]; then
        echo "Graceful shutdown timed out after ${SHUTDOWN_TIMEOUT}s — forcing it off."
        virsh destroy "$VM_NAME" > /dev/null
    fi
}

# Polls `virsh domifaddr` until an IPv4 address is reported or BOOT_IP_TIMEOUT is hit.
vm_wait_for_ip() {
    local waited=0
    local ip=""
    while [[ -z "$ip" && $waited -lt $BOOT_IP_TIMEOUT ]]; do
        ip=$(virsh domifaddr "$VM_NAME" | awk '/ipv4/ {print $4}' | cut -d'/' -f1)
        [[ -n "$ip" ]] && break
        sleep 1
        waited=$((waited + 1))
    done
    echo "$ip"
}

# Polls SSH until it accepts a trivial command or BOOT_SSH_TIMEOUT is hit.
vm_wait_for_ssh() {
    local ip="$1"
    local waited=0
    while [[ $waited -lt $BOOT_SSH_TIMEOUT ]]; do
        if ssh "${SSH_OPTS[@]}" "${VM_USER}@${ip}" "true" 2>/dev/null; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Boots the VM from a powered-off state, waits for it to become reachable, and
# runs the job — this is the VM's equivalent of `docker run --rm`: nothing is
# "warm" beforehand, firmware/kernel boot included in the measurement.
vm_cold_start() {
    vm_ensure_off

    boot_start=$(date +%s%N)
    virsh start "$VM_NAME" > /dev/null

    if [[ -z "$VM_IP" ]]; then
        VM_IP=$(vm_wait_for_ip)
    fi

    if [[ -z "$VM_IP" ]]; then
        echo "Could not detect the VM's IP within ${BOOT_IP_TIMEOUT}s. Set VM_IP manually or increase BOOT_IP_TIMEOUT."
        exit 1
    fi

    if ! vm_wait_for_ssh "$VM_IP"; then
        echo "SSH did not come up within ${BOOT_SSH_TIMEOUT}s of the IP appearing."
        exit 1
    fi

    # PYCMD is a fixed local constant (not external input), so its client-side
    # expansion into the remote command string here is intentional.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "python3 -c '${PYCMD}'"
    boot_end=$(date +%s%N)
    vm_start_ms=$(( (boot_end - boot_start) / 1000000 ))
    echo -e "${YELLOW}VM time (virsh start -> ready -> exec): ${vm_start_ms} ms${NC}"
}

vm_idle_memory() {
    # `free` (no -h) reports in KiB on Alpine's busybox — converted to bytes,
    # then through the same bytes_to_mib() helper the container side uses.
    local used_kib used_bytes
    used_kib=$(ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "free | awk '/Mem:/ {print \$3}'")
    used_bytes=$(( used_kib * 1024 ))
    vm_mem=$(bytes_to_mib "$used_bytes")
    echo -e "${YELLOW}VM memory used: ${vm_mem}${NC}"
}

vm_disk_footprint() {
    if [[ -f "$VM_DISK" ]]; then
        # qcow2 is a sparse format: allocated size is often smaller than the declared
        # virtual size. --block-size=1 reports that allocated size in exact bytes;
        # `du -b` would NOT do the same thing here — GNU du treats -b as shorthand for
        # --apparent-size, which reports the full virtual size instead, defeating the
        # point of measuring "allocated" in the first place.
        local bytes
        bytes=$(du --block-size=1 "$VM_DISK" | cut -f1)
        vm_size=$(bytes_to_mib "$bytes")
        echo -e "${YELLOW}VM disk size (allocated): ${vm_size}${NC}"
    else
        echo -e "${YELLOW}VM disk not found at ${VM_DISK} — check VM_DISK in the script.${NC}"
        vm_size="?"
    fi
}

# Shuts the VM back down — the VM's equivalent of the container's --rm cleanup:
# nothing keeps running once the script exits, on either side.
vm_teardown() {
    virsh shutdown "$VM_NAME" > /dev/null || true
    local waited=0
    while [[ "$(virsh domstate "$VM_NAME")" != "shut off" && $waited -lt $SHUTDOWN_TIMEOUT ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [[ "$(virsh domstate "$VM_NAME")" != "shut off" ]]; then
        virsh destroy "$VM_NAME" > /dev/null
    fi
    echo "VM stopped — nothing left running after the script exits, same as the container's --rm."
}

run_vm_section() {
    section "VM — cold start (full boot: firmware + kernel + init + sshd)"
    vm_cold_start
    section "VM — idle memory"
    vm_idle_memory
    section "VM — disk footprint"
    vm_disk_footprint
    section "VM — teardown (mirrors the container's --rm)"
    vm_teardown
}

# ---------------------------------------------------------------------------
# 3. SUMMARY
# ---------------------------------------------------------------------------

print_summary() {
    section "SUMMARY"
    printf "%-28s %-18s %-18s\n" "Metric" "Container" "VM"
    printf "%-28s %-18s %-18s\n" "------" "---------" "--"
    printf "%-28s %-18s %-18s\n" "Cold start (full lifecycle)" "${container_start_ms} ms" "${vm_start_ms} ms"
    printf "%-28s %-18s %-18s\n" "Idle memory" "${container_mem}" "${vm_mem}"
    printf "%-28s %-18s %-18s\n" "Disk footprint" "${container_size}" "${vm_size}"
}

run_all() {
    run_container_section
    run_vm_section
    print_summary
}

# Only run the full demo when executed directly — sourcing this file (as the
# test scripts do) skips straight to defining the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all
fi
