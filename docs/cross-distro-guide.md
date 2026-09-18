# Cross-Distro Guide

## Overview

PROJ-MK-ULTRA supports running different Linux distributions as child kernel instances, all using the same multikernel kernel.

## How It Works

The multikernel kernel is shared between host and child instances. What differs is the userspace (rootfs):

```
Host: Arch Linux rootfs + multikernel kernel
Child: Debian rootfs + same multikernel kernel
Grandchild: Fedora rootfs + same multikernel kernel
```

## Supported Distributions

### Debian/Ubuntu (debootstrap)

**Requirements:**
- debootstrap installed on host
- Internet connection for package download
- ~2GB disk space per rootfs

**Installation:**
```bash
sudo ./scripts/create-debian-rootfs.sh /mnt/child-root bookworm
```

**Packages installed:**
- linux-image-amd64
- linux-headers-amd64
- systemd
- systemd-sysv
- dbus

### Fedora/RHEL (dnf)

**Requirements:**
- dnf installed on host
- Internet connection for package download
- ~2GB disk space per rootfs

**Installation:**
```bash
sudo ./scripts/create-rpm-rootfs.sh /mnt/child-root 39
```

**Packages installed:**
- @core
- kernel
- kernel-modules
- systemd
- systemd-resolved
- dbus

## Clean vs Messy Combinations

### Clean (Same Init System)

These combinations work well because they share the same init system (systemd):

- Arch → Debian ✓
- Arch → Ubuntu ✓
- Arch → Fedora ✓
- Arch → RHEL ✓
- Debian → Ubuntu ✓
- Fedora → RHEL ✓

### Messy (Different Init Systems)

These combinations are problematic:

- Arch → Alpine (musl + openrc)
- Arch → Gentoo (might use openrc)
- Debian → Alpine (musl + openrc)

### Why It Matters

1. **Init system compatibility** - systemd scripts work across distros
2. **Cgroup management** - systemd handles cgroups consistently
3. **Service management** - systemctl works the same way
4. **Kernel module loading** - Consistent across systemd distros

## Configuration

### Enable Cross-Distro

In `proj-mk-ultra.conf`:
```
CROSS_DISTRO_ENABLE="true"
CHILD_DISTRO="debian"
```

### Security Level

Cross-distro support is available at any security level, but is recommended for **advanced** security level where it combines with leapfrog filesystem diversity for maximum isolation.

## Use Cases

### Security Testing

Test how different distributions handle the same kernel:
- Debian's package manager vs Arch's
- Different default configurations
- Varying security defaults

### Compatibility Testing

Verify child instances work across distributions:
- Library compatibility
- Binary compatibility
- Configuration differences

### Isolation Testing

Test isolation between different distributions:
- Filesystem boundaries
- Process isolation
- Network isolation

## Limitations

### Kernel Modules

Multikernel modules must be installed in each child rootfs. If the child expects modules not compiled in multikernel, they won't be available.

### Package Versions

Different distributions have different package versions. A child running Debian stable may have older packages than the Arch host.

### Kernel Config

The multikernel kernel must have CONFIG options compatible with all child distributions. Some distributions may require specific kernel features.

## Troubleshooting

### Child Fails to Boot

1. Check multikernel modules are installed:
   ```bash
   ls /mnt/child-root/lib/modules/$(uname -r)/
   ```

2. Verify systemd is installed:
   ```bash
   ls /mnt/child-root/usr/lib/systemd/systemd
   ```

3. Check kernel config compatibility:
   ```bash
   zcat /proc/config.gz | grep CONFIG_CGROUP
   ```

### Package Installation Fails

1. Check internet connectivity from host
2. Verify debootstrap/dnf is installed
3. Check available disk space
4. Verify mirror URLs are accessible

### Module Version Mismatch

If child expects different module version:
```bash
# On host, check current kernel version
uname -r

# Install matching modules in child
cp -r /lib/modules/$(uname -r) /mnt/child-root/lib/modules/
```

## Best Practices

1. **Test first** - Try child instances before production use
2. **Use stable releases** - Debian stable, Fedora LTS
3. **Monitor disk space** - Each rootfs uses ~2GB
4. **Keep modules updated** - Sync multikernel modules regularly
5. **Document configurations** - Note which distros work well together
