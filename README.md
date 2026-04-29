<!--
 Copyright 2026-present raml-dev
 SPDX-License-Identifier: MIT
-->

# Linux Packages Repositories

This git repository handles the Linux package-manager publication flow for all [`raml-dev`](https://github.com/raml-dev) projects.

It manages repositories for the following package managers:

- apt (Debian/Ubuntu)
- dnf/yum (Fedora)
- pacman (Arch Linux)

We use [Cloudflare R2](https://www.cloudflare.com/developer-platform/r2/) as the storage backend for the repositories, but the scripts can be easily adapted to use any other S3-compatible storage backend.

## Installation

### Debian / Ubuntu

Add the repo:

```bash
sudo install -d -m0755 /etc/apt/keyrings

curl -fsSL https://linux-packages.ramldev-info.workers.dev/apt/raml-dev-archive-keyring.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/raml-dev-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/raml-dev-archive-keyring.gpg] https://linux-packages.ramldev-info.workers.dev/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/raml-dev.list

sudo apt update
```

To remove it:

```bash
sudo rm -f /etc/apt/sources.list.d/raml-dev.list
sudo rm -f /etc/apt/keyrings/raml-dev-archive-keyring.gpg
sudo apt update
```

## Fedora / RHEL / Other `dnf` or `yum`-based distros

Add the repo:

```bash
sudo curl -fsSL https://linux-packages.ramldev-info.workers.dev/rpm/raml-dev.repo \
  -o /etc/yum.repos.d/raml-dev.repo
```

To remove it:

```bash
sudo rm -f /etc/yum.repos.d/raml-dev.repo
```

## Arch Linux / Arch Linux ARM

Add the repo:

```bash
curl -fsSL https://https://linux-packages.ramldev-info.workers.dev//arch/raml-dev-pacman-key.asc \
  -o /tmp/raml-dev-pacman-key.asc

sudo pacman-key --add /tmp/raml-dev-pacman-key.asc
sudo pacman-key --lsign-key ramldev.info@gmail.com

sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'
[raml-dev]
SigLevel = Required
Server = https://https://linux-packages.ramldev-info.workers.dev//arch/$arch
EOF

sudo pacman -Sy
sudo pacman -S solo
```

To remove it:

```bash
sudo pacman -R solo
sudo sed -i '/^\[raml-dev\]$/,/^$/d' /etc/pacman.conf
sudo pacman -Sy
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
