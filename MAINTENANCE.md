<!--
 Copyright 2026-present raml-dev
 SPDX-License-Identifier: MIT
-->

# Maintenance

## Workflow

The `publish` workflow:

1. Downloads the release assets from GitHub Releases of the project that triggered the run
2. Generates the APT/RPM/pacman metadata
3. Signs the metadata
4. Publishes the repositories to Cloudflare R2

## Configuring a new package

This repository expects to receive a `repository_dispatch` event from a GitHub repository that contains the package to be published.

To publish a package, you need to:

1. Add the `RAML_DEV_AUTOMATIONS_APP_CLIENT_ID` and `RAML_DEV_AUTOMATIONS_APP_PRIVATE_KEY` secrets to the GitHub repository that contains the package to be published.

> [!NOTE]
>
> Only raml-dev owners know how to retrieve the private key.

1. Ensure you build and release Linux packages within your GitHub Actions workflow, with the following artifact names:
    - APT:
        - `<package_name>_<version>_amd64.deb`
        - `<package_name>_<version>_arm64.deb`
    - RPM:
        - `<package_name>-<version>-1.x86_64.rpm`
        - `<package_name>-<version>-1.aarch64.rpm`
    - Arch:
        - `<package_name>-<version>-1-x86_64.pkg.tar.zst`
        - `<package_name>-<version>-1-aarch64.pkg.tar.zst`

2. Dispatch a `repository_dispatch` event to this repository with the following payload:

    ```json
    {
      "event_type": "linux-package-release",
      "client_payload": {
        "release": {
          "version": "${GITHUB_REF_NAME}",
          "api_url": "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/releases/tags/${GITHUB_REF_NAME}"
        },
        "package": {
          "name": "${PACKAGE_NAME}",
          "source_repository": "raml-dev/${REPO}"
        }
      }
    }
    ```

    If your release asset filenames do not match the default conventions, include an optional `assets` override block under `client_payload`:

    ```json
    {
      "client_payload": {
        "assets": {
          "sha256sums": {
            "filename": "SHA256SUMS"
          },
          "apt": {
            "amd64": { "filename": "solo_0.1.1_amd64.deb" },
            "arm64": { "filename": "solo_0.1.1_arm64.deb" }
          },
          "rpm": {
            "x86_64": { "filename": "solo-0.1.1-1.x86_64.rpm" },
            "aarch64": { "filename": "solo-0.1.1-1.aarch64.rpm" }
          },
          "arch": {
            "x86_64": { "filename": "solo-0.1.1-1-x86_64.pkg.tar.zst" },
            "aarch64": { "filename": "solo-0.1.1-1-aarch64.pkg.tar.zst" }
          }
        }
      }
    }
    ```

    If the `assets` block is omitted, this repository derives filenames from:
    - APT: `<package_name>_<version>_<arch>.deb`
    - RPM: `<package_name>-<version>-1.<arch>.rpm`
    - Arch: `<package_name>-<version>-1-<arch>.pkg.tar.zst`

You can see an example of this in the [raml-dev/solo](https://github.com/raml-dev/solo) repository.

## Local testing

This project uses [mise](https://mise.jdx.dev) to manage tooling versions and tasks. It's also used in the workflow, which means that you can test the workflow locally using the same mechanisms as the workflow.

To test the workflow locally:

- Copy `mise.local.toml.example` to `mise.local.toml`
- Populate all variables in `mise.local.toml` with the appropriate values

> [!NOTE]
>
> To run correctly, the task requires armored GPG keys files to be available. For convenience, you can store them in the gitignored `keys` folder. You can test it with your own keys and R2 buckets. DO NOT COMMIT KEYS!
>
> Don't ask for the keys used for our package repositories.
>
> To generate the required keys and test locally:
>
> ```bash
> GPG_KEY_NAME="Local test"
> GPG_KEY_EMAIL="info@example.com"
> gpg --batch --quick-generate-key "${GPG_KEY_NAME} <${GPG_KEY_EMAIL}>" rsa4096 sign 2y
> gpg --armor --export-secret-keys "${GPG_KEY_NAME}" > local-test-signing-private.asc
> gpg --armor --export "${GPG_KEY_NAME}" > local-test-archive-keyring.asc
> ```
>
> You can choose to create a single key for all repositories or one key per repository, the important thing is to ensure all env variables in `mise.local.toml` are populated with the correct values.

- Run:

    ```bash
    mise install
    mise run local-publish-test
    ```
