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

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
