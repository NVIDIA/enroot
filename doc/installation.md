# Installation

## From packages

Two package flavors are available, standard and hardened. As a rule of thumb, the hardened flavor will be slightly more secure but will suffer from a larger overhead.

The table below describes each package flavor and their characteristics:

<table>
    <thead>
        <tr>
            <th>Flavor</th>
            <th>Package</th>
            <th>Description</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td rowspan=2>Standard</td>
            <td align="center"><code>enroot</code></td>
            <td>
                <p>Main utility, helper binaries and standard configuration files.</p>
                <ul>
                  <li><i>Spectre variant 2 (IBPB/STIBP) mitigations are disabled</i></li>
                  <li><i>Spectre variant 4 (SSBD) mitigations are disabled</i></li>
                </ul>
            </td>
        </tr>
        <tr>
            <td align="center"><code>enroot+caps</code></td>
            <td>Grants extra capabilities to unprivileged users which allows<br> them to import and convert container images.</td>
        </tr>
        <tr>
            <td rowspan=2>Hardened</td>
            <td align="center"><code>enroot-hardened</code></td>
            <td>Main utility, helper binaries and standard configuration files.</td>
        </tr>
        <tr>
            <td align="center"><code>enroot-hardened+caps</code></td>
            <td>Grants extra capabilities to unprivileged users which allows<br> them to import and convert container images.</td>
        </tr>
    </tbody>
</table>

#### Standard flavor

```sh
# Debian-based distributions
curl -fSsL -O https://github.com/NVIDIA/enroot/releases/download/v1.0.0/enroot_1.0.0-1_amd64.deb
curl -fSsL -O https://github.com/NVIDIA/enroot/releases/download/v1.0.0/enroot+caps_1.0.0-1_amd64.deb # optional
sudo apt install -y ./*.deb

# RHEL-based distributions
sudo yum install -y epel-release # required on some distributions
sudo yum install -y https://github.com/NVIDIA/enroot/releases/download/v1.0.0/enroot-1.0.0-1.el7.x86_64.rpm
sudo yum install -y https://github.com/NVIDIA/enroot/releases/download/v1.0.0/enroot+caps-1.0.0-1.el7.x86_64.rpm # optional
```

#### Hardened flavor

```sh
# Debian-based distributions
curl -fSsL -O https://github.com/NVIDIA/enroot/releases/download/v1.0.0/enroot-hardened_1.0.0-1_amd64.deb
curl -fSsL -O https://github.com/NVIDIA/enroot/releases/download/v1.0.0/enroot-hardened+caps_1.0.0-1_amd64.deb # optional
sudo apt install -y ./*.deb

# RHEL-based distributions
sudo yum install -y epel-release # required on some distributions
sudo yum install -y https://github.com/NVIDIA/enroot/releases/download/v1.0.0/enroot-hardened-1.0.0-1.el7.x86_64.rpm
sudo yum install -y https://github.com/NVIDIA/enroot/releases/download/v1.0.0/enroot-hardened+caps-1.0.0-1.el7.x86_64.rpm # optional
```

## From source

Install the build dependencies and clone the repository:
```sh
# Debian-based distributions
sudo apt install -y git gcc make libcap2-bin libtool

# RHEL-based distributions:
sudo yum install -y git gcc make libcap libtool

# Archlinux-based distributions:
sudo pacman --noconfirm -S git gcc make libtool

git clone --recurse-submodules https://github.com/NVIDIA/enroot.git
```

Install the runtime dependencies:
```sh
# Debian-based distributions
sudo apt install -y curl gawk jq squashfs-tools parallel
sudo apt install -y fuse-overlayfs libnvidia-container-tools pigz pv squashfuse # optional

# RHEL-based distributions
sudo yum install -y epel-release # required on some distributions
sudo yum install -y jq squashfs-tools parallel
sudo yum install -y fuse-overlayfs libnvidia-container-tools pigz pv squashfuse # optional

# Archlinux-based distributions
sudo pacman --noconfirm -S jq parallel squashfs-tools
sudo pacman --noconfirm -S fuse-overlayfs libnvidia-container-tools pigz pv squashfuse # optional
```

Build and install Enroot:
```sh
cd enroot
sudo make install
```

In order to allow unprivileged users to import images:
```sh
sudo make setcap
```
