#!/usr/bin/env bash
#
# Usage: ./demo-container-vs-vm.sh

set -euo pipefail

IMAGE="python:3.14-alpine"
VM_NAME="alpine-demo"
VM_DISK="$HOME/vm-demo/alpine.qcow2"
VM_USER="root"
VM_IP=""   # empty = auto-detect via virsh domifaddr
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
section "CONTAINER — cold start"

start=$(date +%s%N)
docker run --rm "$IMAGE" python3 -c "$PYCMD"
end=$(date +%s%N)
container_start_ms=$(( (end - start) / 1000000 ))
echo -e "${GREEN}Container time: ${container_start_ms} ms${NC}"

section "CONTAINER — idle memory"

docker run -d --rm --name demo-mem "$IMAGE" sleep 60 > /dev/null
sleep 1
container_mem=$(docker stats --no-stream --format "{{.MemUsage}}" demo-mem)
echo -e "${GREEN}Container memory: ${container_mem}${NC}"
docker stop demo-mem > /dev/null

section "CONTAINER — disk footprint"

container_size=$(docker images "$IMAGE" --format "{{.Size}}")
echo -e "${GREEN}Container image size: ${container_size}${NC}"

# ---------------------------------------------------------------------------
# 2. VM (libvirt/virsh, already running)
# ---------------------------------------------------------------------------
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

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

section "VM — cold start"

start=$(date +%s%N)
ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "python3 -c '${PYCMD}'"
end=$(date +%s%N)
vm_start_ms=$(( (end - start) / 1000000 ))
echo -e "${YELLOW}VM time (SSH + exec): ${vm_start_ms} ms${NC}"

section "VM — idle memory"

vm_mem=$(ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "free -h | awk '/Mem:/ {print \$3\" / \"\$2}'")
echo -e "${YELLOW}VM memory used: ${vm_mem}${NC}"

section "VM — disk footprint"

if [[ -f "$VM_DISK" ]]; then
    # qcow2 is a sparse format: allocated size is often smaller than the declared virtual size
    vm_size=$(du -h "$VM_DISK" | cut -f1)
    echo -e "${YELLOW}VM disk size (allocated): ${vm_size}${NC}"
else
    echo -e "${YELLOW}VM disk not found at ${VM_DISK} — check VM_DISK in the script.${NC}"
    vm_size="?"
fi

# ---------------------------------------------------------------------------
# 3. SUMMARY
# ---------------------------------------------------------------------------
section "SUMMARY"

printf "%-20s %-15s %-15s\n" "Metric" "Container" "VM"
printf "%-20s %-15s %-15s\n" "------" "---------" "--"
printf "%-20s %-15s %-15s\n" "Cold start" "${container_start_ms} ms" "${vm_start_ms} ms"
printf "%-20s %-15s %-15s\n" "Idle memory" "${container_mem}" "${vm_mem}"
printf "%-20s %-15s %-15s\n" "Disk footprint" "${container_size}" "${vm_size}"