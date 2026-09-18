
# Demo: Containers vs VMs

Live demo script comparing a Docker container and a libvirt/QEMU VM across three metrics:
cold start time, idle memory, disk footprint. Test job: a simple `print("hello world")` in Python.

## Prerequisites

- Docker installed and working
- `libvirt` + `virt-manager` (or `virt-install` on the CLI), with the `default` network active
- An Alpine Linux VM already created and configured (see below)
- Key-based SSH (no password) to the VM

## VM setup (one-time, done ahead of the demo)

```bash
mkdir -p ~/vm-demo
qemu-img create -f qcow2 ~/vm-demo/alpine.qcow2 1G

virt-install \
  --connect qemu:///system \
  --name alpine-demo \
  --memory 512 \
  --vcpus 1 \
  --disk path=$HOME/vm-demo/alpine.qcow2,format=qcow2 \
  --cdrom alpine-virt-3.24.1-x86_64.iso \
  --os-variant alpinelinux3.19 \
  --network network=default \
  --graphics none \
  --console pty,target_type=serial
```

In the installer console:

1. Log in as `root` (no password on the live ISO)
2. `setup-alpine` — answer the prompts, choose disk `vda` in `sys` mode
3. `reboot` once installation finishes

Once rebooted into the installed system:

```bash
apk update
apk add python3 openssh
service sshd start   # usually already enabled by setup-alpine
```

### Passwordless SSH access

Temporarily allow password auth long enough to install the key (Alpine blocks
password auth for root by default):

```bash
# On the VM
sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
service sshd restart
mkdir -p /root/.ssh && chmod 700 /root/.ssh
```

```bash
# From the host
ssh-copy-id root@<VM_IP>
```

Get the VM's IP with:

```bash
virsh --connect qemu:///system domifaddr alpine-demo
```

**Important note**: on this setup, `virsh` without `--connect qemu:///system` defaults
to `qemu:///session`, where the domain doesn't exist — always specify the connection
explicitly (the script does this automatically).

## Usage

```bash
virsh --connect qemu:///system start alpine-demo   # if not already running
docker pull python:3.14-alpine                      # ahead of time, off the clock
./demo-container-vs-vm.sh
```

## Configuration

Variables at the top of the script to adjust if needed:

| Variable    | Description                 | Default                        |
| ----------- | --------------------------- | ------------------------------ |
| `IMAGE`   | Docker image used           | `python:3.14-alpine`         |
| `VM_NAME` | libvirt domain name         | `alpine-demo`                |
| `VM_DISK` | Path to the qcow2 disk      | `$HOME/vm-demo/alpine.qcow2` |
| `VM_USER` | SSH user on the VM          | `root`                       |
| `VM_IP`   | VM IP (empty = auto-detect) | *(empty)*                    |

## Why these choices

- **Alpine** (both container and VM): minimal image/OS, so the measured gap reflects
  virtualization overhead rather than the weight of the OS itself.
- **`docker pull` and VM already running before the demo**: otherwise the measured
  "cold start" would include the image download or a full kernel boot, skewing the
  intended comparison (runtime overhead only).
- **Allocated qcow2 size, not virtual size**: qcow2 is a sparse format, so the actual
  size on disk is often smaller than the 1G declared at creation.
