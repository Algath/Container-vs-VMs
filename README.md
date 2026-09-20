# Demo: Containers vs VMs

Live demo script comparing a Docker container and a libvirt/QEMU VM across three metrics: cold start time, idle memory, disk footprint. Test job: a simple `print("hello world")` in Python.

## Prerequisites

- Docker installed and working
- `libvirt` + `virt-manager` (or `virt-install` on the CLI), with the `default` network active
- An Alpine Linux VM already created and configured (see below)
- Key-based SSH (no password) to the VM

## VM setup (one-time, done ahead of the demo)

Download the Alpine `virt` ISO — the minimal flavor meant for VMs, not the `standard` or `extended` ones — from the official CDN (adjust the version if a newer one is out):

```Shell
mkdir -p ~/vm-demo && cd ~/vm-demo
wget https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-virt-3.24.1-x86_64.iso
```

`virt-install` does not fetch the ISO itself — `--cdrom` expects a file already present locally, so this download has to happen first and the following commands assume you're still in `~/vm-demo/`.

```bash
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

## SSH access to the VM: a dedicated user, password first, then a key

Root is never used for SSH here. Logging in as root over the network is a needless privilege escalation risk — anyone who guesses or leaks that one credential gets full control of the machine immediately, with no separation between "the account you log in as" and "the account that can do anything." A normal, unprivileged user is the right default for SSH access, exactly like on a real server.

1. **Create the user, on the VM (console), while it's still fresh from setup-alpine:**

```Shell
adduser demo
```

2. **Get the VM's IP** (from the host)

```Shell
virsh --connect qemu:///system domifaddr alpine-demo
```

**Important note** : on this setup, `virsh` without `--connect qemu:///system` defaults to `qemu:///session`, where the domain doesn't exist — always specify the connection explicitly (the script does this automatically).

3. **First connection, by password**

```Shell
ssh demo@<VM_IP>
```

4. **Generate a key pair for this user** (on the host, skip if you already have one):

```Shell
ssh-keygen -t ed25519 -f ~/.ssh/vm_demo_key
```

5. **Install the public key for** `demo`, switch to key-based auth.

This copies the host's public SSH key into `authorized_keys` on the VM, for that one user — it will ask for the `demo` password one last time, to authorize the installation:

```Shell
ssh-copy-id -i ~/.ssh/vm_demo_key.pub demo@<VM_IP>
```

6. **No password log in**

```Shell
ssh -i ~/.ssh/vm_demo_key demo@<VM_IP>
```

Because this is a custom-named key, SSH won't find it automatically: `-i` tells it exactly which private key to use for authentication. The VM's SSH server then sends a cryptographic challenge, and the client uses that private key to prove it matches the public key already stored, without the private key itself ever leaving the host.

That sequence, password login working like on any box, then swapping to a key, is the point: the key isn't there to remove a "clerical" step, it's there because password auth over the network is brute-forceable and a key isn't. Root SSH stays disabled throughout (Alpine's default `PermitRootLogin prohibit-password` is left untouched); the demo's Python job also runs as `demo`, not root, for the same least-privilege reason.

### Usage

```bash
virsh --connect qemu:///system start alpine-demo   # if not already running
docker pull python:3.14-alpine                      # ahead of time, off the clock
./demo-container-vs-vm.sh
```

## ISO vs. container image: not the same kind of artifact

The demo uses two different kinds of "package" for the two worlds, and they aren't interchangeable concepts:

* **The Alpine ISO** is a bootable installation medium — a disk image containing an installer and a kernel, meant to be attached as virtual (or physical) removable media and used to *install* an OS onto a disk. It doesn't run as-is; it's a one-time step that produces the qcow2 disk the VM actually boots from afterward. This is why the ISO is
  only referenced once, in `virt-install`, and never again once `alpine.qcow2` exists.
* **A Docker image** (`python:3.14-alpine` here) is not an installer — it's already the runnable root filesystem, built from stacked, read-only **layers** (each `RUN`/`COPY` in the image's Dockerfile adds one, cached and reused across images that share a base). `docker run` doesn't install anything; it adds a thin writable layer on top and starts
  the process directly, sharing the host's kernel instead of booting one.

That difference is part of why the two "cold start" numbers aren't symmetric: the container skips an install step and a kernel boot entirely, while the VM's ISO-based install (done once, ahead of the demo) is the one-time cost that a container's layered image never has to pay at all.

## Continuous integration

A workflow (`.github/workflows/ci.yml`) runs on every push and pull request:

* **`lint`** : runs `shellcheck` on the bash scripts, catching quoting bugs, unset variables, and other shell pitfalls before they hit a live demo.
* **`container-tests`** (`tests/test-container.sh`): builds both container images, checks that the job prints the expected output, that the image size metric can be read, and that the SSH-enabled container accepts a key-based login as the `demo` user, i.e. everything on the Docker side of the demo, end to end.

Both `tests/test-container.sh` and `tests/test-vm.sh` source `demo-container-vs-vm.sh` and call its individual functions (`container_cold_start`, `vm_disk_footprint`, etc.) rather than re-typing the same `docker`/`ssh` commands in a separate file — they test the
actual demo code, and can never silently drift out of sync with it. Running the script directly (`./demo-container-vs-vm.sh`) still runs the full container-then-VM sequence end to end; a guard at the bottom of the file (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`) only skips that when the file is sourced instead of executed.

 **A terminology note, since it's easy to conflate the two** : `runs-on: ubuntu-latest` in`ci.yml` means each job itself executes inside a GitHub-provided VM, that's what "runs-on" refers to, and it's unrelated to `alpine-demo`, the libvirt VM this project measures. A GitHub Actions runner has no network route to `alpine-demo` (it lives on this host's
private `192.168.122.0/24` libvirt network) and starts from a clean disk on every run, so there's no way to reach or reconstruct it from a workflow step, regardless of what dependencies that step installs.

**The VM side is deliberately not covered by CI.** It depends on a libvirt VM that was provisioned once, by hand, and keeps state across runs, an installed disk, a user account, a deployed SSH key. A GitHub Actions runner starts from a clean slate on every run, so testing the VM path automatically would mean re-running the ISO install, the `setup-alpine` prompts, and the SSH key setup from scratch each time, several minutes of work, on infrastructure (nested virtualization) that isn't guaranteed to behave the same way on every runner, just to check a path that isn't going to change between pushes. That trade-off, CI catches regressions in the parts that are actually code (scripts, Dockerfile, container behavior), while the VM setup stays a documented, manually-verified procedure, is intentional, not an oversight.

That manual verification isn't just "trust me", `tests/test-vm.sh` runs the same checks as `tests/test-container.sh` (VM up, correct user, job output, root login refused, metrics readable), against the real VM, from the host that has it. It's not wired into the workflow since a GitHub-hosted runner has no route to a VM sitting on a private libvirt network, it's meant to be run locally before a live demo, with its output kept as evidence that the VM path was actually exercised, not just documented:

```Shell
./tests/test-vm.sh
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

- **Alpine** (both container and VM): minimal image/OS, so the measured gap reflects virtualization overhead rather than the weight of the OS itself.
- **`docker pull` and VM already running before the demo**: otherwise the measured "cold start" would include the image download or a full kernel boot, skewing the intended comparison (runtime overhead only).
- **Allocated qcow2 size, not virtual size**: qcow2 is a sparse format, so the actual size on disk is often smaller than the 1G declared at creation.
