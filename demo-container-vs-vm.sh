#!/usr/bin/env bash
#
# Live demo: Containers vs VMs — cold start, idle memory, disk footprint
# See README.md for prerequisites and full setup.
#
# Usage: ./demo-container-vs-vm.sh

set -euo pipefail

IMAGE="python:3.14-alpine"
PYCMD='print("hello world")'

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

section() {
    echo -e "\n${CYAN}=== $1 ===${NC}"
}

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
# 2. VM
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 3. SUMMARY
# ---------------------------------------------------------------------------
section "SUMMARY"

printf "%-20s %-15s %-15s\n" "Metric" "Container"
printf "%-20s %-15s %-15s\n" "------" "---------"
printf "%-20s %-15s %-15s\n" "Cold start" "${container_start_ms} ms"
printf "%-20s %-15s %-15s\n" "Idle memory" "${container_mem}"
printf "%-20s %-15s %-15s\n" "Disk footprint" "${container_size}"