# Copyright 2026-present raml-dev
# SPDX-License-Identifier: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

SHA256_ASSET_NAME="$(release_sha256sums_asset_name)"
CURRENT_RELEASE_INFO_PATH="${WORK_DIR}/release.json"
EXPECTED_DEB_VERSION_PREFIX="${PACKAGE_RELEASE_VERSION}-"
EXPECTED_ARCH_VERSION_PREFIX="${PACKAGE_RELEASE_VERSION}-"

release_api_headers() {
  if [[ -n "${SOURCE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    printf '%s\n' \
      "-H" "Authorization: Bearer ${SOURCE_GITHUB_TOKEN:-${GITHUB_TOKEN}}" \
      "-H" "Accept: application/vnd.github+json"
  else
    printf '%s\n' "-H" "Accept: application/vnd.github+json"
  fi
}

fetch_release_json() {
  local -a curl_args

  mapfile -t curl_args < <(release_api_headers)
  if ! curl -fsSL "${curl_args[@]}" "${PACKAGE_RELEASE_API_URL}" > "${CURRENT_RELEASE_INFO_PATH}"; then
    curl -fsSL -H "Accept: application/vnd.github+json" "${PACKAGE_RELEASE_API_URL}" > "${CURRENT_RELEASE_INFO_PATH}"
  fi
}

release_asset_api_url() {
  local asset_name="$1"
  jq -r --arg asset_name "${asset_name}" '
    .assets[]
    | select(.name == $asset_name)
    | .url
  ' "${CURRENT_RELEASE_INFO_PATH}"
}

release_asset_browser_url() {
  local asset_name="$1"
  jq -r --arg asset_name "${asset_name}" '
    .assets[]
    | select(.name == $asset_name)
    | .browser_download_url
  ' "${CURRENT_RELEASE_INFO_PATH}"
}

download_release_asset() {
  local asset_name="$1"
  local output_path="$2"
  local asset_api_url browser_url
  local -a curl_args

  asset_api_url="$(release_asset_api_url "${asset_name}")"
  browser_url="$(release_asset_browser_url "${asset_name}")"

  if [[ -n "${asset_api_url}" && "${asset_api_url}" != "null" ]]; then
    mapfile -t curl_args < <(release_api_headers)
    if curl -fsSL "${curl_args[@]}" -H "Accept: application/octet-stream" "${asset_api_url}" > "${output_path}"; then
      return
    fi
  fi

  if [[ -z "${browser_url}" || "${browser_url}" == "null" ]]; then
    die "release asset not found: ${asset_name}"
  fi

  curl -fsSL "${browser_url}" > "${output_path}"
}

sha256_expected_for_asset() {
  local asset_name="$1"
  awk -v asset_name="${asset_name}" '$2 == asset_name { print $1 }' "$(release_download_path "${SHA256_ASSET_NAME}")"
}

verify_downloaded_asset_hash() {
  local asset_name="$1"
  local expected actual

  expected="$(sha256_expected_for_asset "${asset_name}")"
  [[ -n "${expected}" ]] || die "asset ${asset_name} is missing from ${SHA256_ASSET_NAME}"
  actual="$(sha256sum "$(release_download_path "${asset_name}")" | awk '{print $1}')"
  [[ "${expected}" == "${actual}" ]] || die "SHA256 mismatch for ${asset_name}"
}

validate_release() {
  jq -e '.prerelease == false' "${CURRENT_RELEASE_INFO_PATH}" >/dev/null || die "refusing to ingest a prerelease"
  jq -e '.draft == false' "${CURRENT_RELEASE_INFO_PATH}" >/dev/null || die "refusing to ingest a draft release"
}

validate_package_dispatch() {
  [[ -n "${PACKAGE_NAME}" ]] || die "missing package name"
  [[ -n "${PACKAGE_SOURCE_REPOSITORY}" ]] || die "missing source repository"
  case "${PACKAGE_RELEASE_API_URL}" in
    */repos/"${PACKAGE_SOURCE_REPOSITORY}"/releases/*) ;;
    *)
      die "dispatch source repository mismatch for release API URL: expected ${PACKAGE_SOURCE_REPOSITORY}"
      ;;
  esac
}

download_required_assets() {
  local arch asset_name

  download_release_asset "${SHA256_ASSET_NAME}" "$(release_download_path "${SHA256_ASSET_NAME}")"

  for arch in "${APT_ARCHITECTURES[@]}"; do
    asset_name="$(release_deb_asset_name "${arch}")"
    download_release_asset "${asset_name}" "$(release_download_path "${asset_name}")"
    verify_downloaded_asset_hash "${asset_name}"
  done

  for arch in "${RPM_ARCHITECTURES[@]}"; do
    asset_name="$(release_rpm_asset_name "${arch}")"
    download_release_asset "${asset_name}" "$(release_download_path "${asset_name}")"
    verify_downloaded_asset_hash "${asset_name}"
  done

  for arch in "${ARCH_ARCHITECTURES[@]}"; do
    asset_name="$(release_arch_asset_name "${arch}")"
    download_release_asset "${asset_name}" "$(release_download_path "${asset_name}")"
    verify_downloaded_asset_hash "${asset_name}"
  done
}

validate_deb_metadata() {
  local arch asset_name deb_path package_name_value version architecture

  for arch in "${APT_ARCHITECTURES[@]}"; do
    asset_name="$(release_deb_asset_name "${arch}")"
    deb_path="$(release_download_path "${asset_name}")"

    package_name_value="$(dpkg_field "${deb_path}" Package)"
    version="$(dpkg_field "${deb_path}" Version)"
    architecture="$(dpkg_field "${deb_path}" Architecture)"
    [[ "${package_name_value}" == "${PACKAGE_NAME}" ]] || die "unexpected package name in ${asset_name}: ${package_name_value}"
    case "${version}" in
      "${EXPECTED_DEB_VERSION_PREFIX}"*) ;;
      *) die "unexpected package version in ${asset_name}: ${version}" ;;
    esac
    [[ "${architecture}" == "${arch}" ]] || die "unexpected package architecture in ${asset_name}: ${architecture}"
  done
}

validate_rpm_metadata() {
  local arch asset_name rpm_path package_name_value version release architecture

  for arch in "${RPM_ARCHITECTURES[@]}"; do
    asset_name="$(release_rpm_asset_name "${arch}")"
    rpm_path="$(release_download_path "${asset_name}")"

    package_name_value="$(rpm_field "${rpm_path}" '%{NAME}')"
    version="$(rpm_field "${rpm_path}" '%{VERSION}')"
    release="$(rpm_field "${rpm_path}" '%{RELEASE}')"
    architecture="$(rpm_field "${rpm_path}" '%{ARCH}')"
    [[ "${package_name_value}" == "${PACKAGE_NAME}" ]] || die "unexpected package name in ${asset_name}: ${package_name_value}"
    [[ "${version}" == "${PACKAGE_RELEASE_VERSION}" ]] || die "unexpected package version in ${asset_name}: ${version}"
    [[ "${release}" == "1" ]] || die "unexpected RPM release in ${asset_name}: ${release}"
    [[ "${architecture}" == "${arch}" ]] || die "unexpected package architecture in ${asset_name}: ${architecture}"
  done
}

validate_arch_metadata() {
  local arch asset_name package_path version release architecture

  for arch in "${ARCH_ARCHITECTURES[@]}"; do
    asset_name="$(release_arch_asset_name "${arch}")"
    package_path="$(release_download_path "${asset_name}")"

    [[ "$(arch_pkginfo_field "${package_path}" pkgname)" == "${PACKAGE_NAME}" ]] || die "unexpected package name in ${asset_name}: $(arch_pkginfo_field "${package_path}" pkgname)"
    version="$(arch_pkginfo_field "${package_path}" pkgver)"
    release="$(arch_pkginfo_field "${package_path}" pkgrel)"
    architecture="$(arch_pkginfo_field "${package_path}" arch)"
    case "${version}" in
      "${PACKAGE_RELEASE_VERSION}"|"${EXPECTED_ARCH_VERSION_PREFIX}"*) ;;
      *) die "unexpected package version in ${asset_name}: ${version}" ;;
    esac
    if [[ -n "${release}" ]]; then
      [[ "${release}" == "1" ]] || die "unexpected package release in ${asset_name}: ${release}"
    fi
    [[ "${architecture}" == "${arch}" ]] || die "unexpected package architecture in ${asset_name}: ${architecture}"
  done
}

write_publish_context() {
  jq -n \
    --arg sha256sums_filename "${SHA256_ASSET_NAME}" \
    --arg apt_amd64_filename "$(release_deb_asset_name amd64)" \
    --arg apt_amd64_pool_path "$(apt_pool_relative_path "$(release_deb_asset_name amd64)")" \
    --arg apt_arm64_filename "$(release_deb_asset_name arm64)" \
    --arg apt_arm64_pool_path "$(apt_pool_relative_path "$(release_deb_asset_name arm64)")" \
    --arg rpm_x86_64_filename "$(release_rpm_asset_name x86_64)" \
    --arg rpm_x86_64_repo_path "$(rpm_repo_relative_path x86_64 "$(release_rpm_asset_name x86_64)")" \
    --arg rpm_aarch64_filename "$(release_rpm_asset_name aarch64)" \
    --arg rpm_aarch64_repo_path "$(rpm_repo_relative_path aarch64 "$(release_rpm_asset_name aarch64)")" \
    --arg arch_x86_64_filename "$(release_arch_asset_name x86_64)" \
    --arg arch_x86_64_repo_path "$(arch_repo_relative_path x86_64 "$(release_arch_asset_name x86_64)")" \
    --arg arch_aarch64_filename "$(release_arch_asset_name aarch64)" \
    --arg arch_aarch64_repo_path "$(arch_repo_relative_path aarch64 "$(release_arch_asset_name aarch64)")" \
    '
    {
      assets: {
        sha256sums: {
          filename: $sha256sums_filename
        },
        apt: {
          amd64: {
            filename: $apt_amd64_filename,
            pool_path: $apt_amd64_pool_path
          },
          arm64: {
            filename: $apt_arm64_filename,
            pool_path: $apt_arm64_pool_path
          }
        },
        rpm: {
          x86_64: {
            filename: $rpm_x86_64_filename,
            repo_path: $rpm_x86_64_repo_path
          },
          aarch64: {
            filename: $rpm_aarch64_filename,
            repo_path: $rpm_aarch64_repo_path
          }
        },
        arch: {
          x86_64: {
            filename: $arch_x86_64_filename,
            repo_path: $arch_x86_64_repo_path
          },
          aarch64: {
            filename: $arch_aarch64_filename,
            repo_path: $arch_aarch64_repo_path
          }
        }
      }
    }
    ' > "${PUBLISH_CONTEXT_PATH}"
}

main() {
  require_env "PACKAGE_NAME"
  require_env "PACKAGE_SOURCE_REPOSITORY"
  require_env "PACKAGE_RELEASE_VERSION"
  require_env "PACKAGE_RELEASE_API_URL"
  require_env "PACKAGE_DISPATCH_PAYLOAD"
  prepare_work_dirs

  log "fetching release..."
  fetch_release_json
  log "validating release..."
  validate_release
  log "validating package dispatch..."
  validate_package_dispatch
  log "downloading required assets..."
  download_required_assets
  log "validating deb metadata..."
  validate_deb_metadata
  log "validating rpm metadata..."
  validate_rpm_metadata
  log "validating arch metadata..."
  validate_arch_metadata
  log "writing publish context..."
  write_publish_context
}

main "$@"
