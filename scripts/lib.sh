# Copyright 2026-present raml-dev
# SPDX-License-Identifier: MIT

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${REPO_WORK_DIR:-${RUNNER_TEMP:-/tmp}/linux-packages-repos-work}"
TMP_DIR="${WORK_DIR}/tmp"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
PUBLISH_CONTEXT_PATH="${WORK_DIR}/publish-context.json"

APT_ARCHITECTURES=("amd64" "arm64")
RPM_ARCHITECTURES=("x86_64" "aarch64")
ARCH_ARCHITECTURES=("x86_64" "aarch64")

APT_ORIGIN="raml-dev"
APT_LABEL="raml-dev"
APT_COMPONENT="main"
APT_DESCRIPTION="raml-dev APT repository"
APT_SUITE="stable"
RPM_REPO_ID="raml-dev"
RPM_REPO_NAME="raml-dev"
ARCH_REPO_ID="raml-dev"
ARCH_REPO_NAME="raml-dev"

log() {
  printf '[linux-packages-repos] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "missing required environment variable: ${name}"
  fi
}

require_python_module() {
  local module_name="$1"
  python3 -c "import ${module_name}" >/dev/null 2>&1 \
    || die "python3 module is required but unavailable: ${module_name}"
}

prepare_work_dirs() {
  mkdir -p "${TMP_DIR}" "${DOWNLOAD_DIR}"
}

release_download_path() {
  local filename="$1"
  printf '%s\n' "${DOWNLOAD_DIR}/${filename}"
}

require_publish_context() {
  [[ -f "${PUBLISH_CONTEXT_PATH}" ]] || die "missing publish context: ${PUBLISH_CONTEXT_PATH}"
}

publish_context_asset_field() {
  local format="$1"
  local arch="$2"
  local field="$3"
  local value

  require_publish_context
  value="$(
    jq -r \
      --arg format "${format}" \
      --arg arch "${arch}" \
      --arg field "${field}" \
      '.assets[$format][$arch][$field] // empty' \
      "${PUBLISH_CONTEXT_PATH}"
  )"

  [[ -n "${value}" ]] || die "missing ${format} asset ${field} for ${arch}"
  printf '%s\n' "${value}"
}

current_release_asset_download_path() {
  local format="$1"
  local arch="$2"

  release_download_path "$(publish_context_asset_field "${format}" "${arch}" filename)"
}

dispatch_payload_query() {
  require_env "PACKAGE_DISPATCH_PAYLOAD"
  jq -r "$@" <<<"${PACKAGE_DISPATCH_PAYLOAD}"
}

dispatch_asset_override_filename() {
  local format="$1"
  local arch="$2"

  dispatch_payload_query \
    --arg format "${format}" \
    --arg arch "${arch}" \
    '.assets[$format][$arch].filename // empty'
}

dispatch_sha256sums_filename() {
  dispatch_payload_query '.assets.sha256sums.filename // empty'
}

package_initial() {
  [[ -n "${PACKAGE_NAME}" ]] || die "missing package name"
  printf '%s\n' "${PACKAGE_NAME:0:1}"
}

release_deb_asset_name() {
  local arch="$1"
  local override

  override="$(dispatch_asset_override_filename apt "${arch}")"
  if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
    return
  fi

  printf '%s\n' "${PACKAGE_NAME}_${PACKAGE_RELEASE_VERSION}_${arch}.deb"
}

release_rpm_asset_name() {
  local arch="$1"
  local override

  override="$(dispatch_asset_override_filename rpm "${arch}")"
  if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
    return
  fi

  printf '%s\n' "${PACKAGE_NAME}-${PACKAGE_RELEASE_VERSION}-1.${arch}.rpm"
}

release_arch_asset_name() {
  local arch="$1"
  local override

  override="$(dispatch_asset_override_filename arch "${arch}")"
  if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
    return
  fi

  printf '%s\n' "${PACKAGE_NAME}-${PACKAGE_RELEASE_VERSION}-1-${arch}.pkg.tar.zst"
}

release_sha256sums_asset_name() {
  local override

  override="$(dispatch_sha256sums_filename)"
  if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
    return
  fi

  printf '%s\n' "SHA256SUMS"
}

apt_pool_relative_path() {
  local filename="$1"
  printf '%s\n' "pool/main/$(package_initial)/${PACKAGE_NAME}/${filename}"
}

rpm_repo_relative_path() {
  local arch="$1"
  local filename="$2"
  printf '%s\n' "stable/${arch}/Packages/$(package_initial)/${filename}"
}

arch_repo_relative_path() {
  local arch="$1"
  local filename="$2"
  printf '%s\n' "${arch}/${filename}"
}

dpkg_field() {
  local deb_path="$1"
  local field="$2"
  dpkg-deb -f "${deb_path}" "${field}" 2>/dev/null || true
}

rpm_field() {
  local rpm_path="$1"
  local query="$2"
  rpm -qp --qf "${query}" "${rpm_path}" 2>/dev/null || true
}

arch_pkginfo_contents() {
  local package_path="$1"

  if bsdtar -xOf "${package_path}" .PKGINFO 2>/dev/null; then
    return
  fi

  bsdtar -xOf "${package_path}" ./.PKGINFO 2>/dev/null
}

arch_pkginfo_field() {
  local package_path="$1"
  local field="$2"

  arch_pkginfo_contents "${package_path}" | awk -F ' = ' -v field="${field}" '$1 == field { print $2; exit }'
}

s3_endpoint_url() {
  printf 'https://%s.r2.cloudflarestorage.com\n' "${CLOUDFLARE_ACCOUNT_ID}"
}

s3_require_credentials() {
  require_env "CLOUDFLARE_ACCOUNT_ID"
  require_env "AWS_ACCESS_KEY_ID"
  require_env "AWS_SECRET_ACCESS_KEY"
  require_env "BUCKET_NAME"
  command -v aws >/dev/null 2>&1 || die "aws CLI is required for packages publication"
}

s3_cp_file() {
  local source="$1"
  local destination="$2"

  s3_require_credentials
  aws s3 cp \
    "${source}" \
    "s3://${BUCKET_NAME}/${destination}" \
    --endpoint-url "$(s3_endpoint_url)" \
    --only-show-errors
}

s3_object_exists() {
  local destination="$1"

  s3_require_credentials
  aws s3api head-object \
    --bucket "${BUCKET_NAME}" \
    --key "${destination}" \
    --endpoint-url "$(s3_endpoint_url)" \
    >/dev/null 2>&1
}

s3_prefix_exists() {
  local prefix="$1"

  s3_require_credentials
  aws s3api list-objects-v2 \
    --bucket "${BUCKET_NAME}" \
    --prefix "${prefix}" \
    --max-keys 1 \
    --endpoint-url "$(s3_endpoint_url)" \
    --query 'KeyCount' \
    --output text \
    2>/dev/null | grep -qx '[1-9][0-9]*'
}

s3_download_file() {
  local source_key="$1"
  local destination_path="$2"

  s3_require_credentials
  aws s3 cp \
    "s3://${BUCKET_NAME}/${source_key}" \
    "${destination_path}" \
    --endpoint-url "$(s3_endpoint_url)" \
    --only-show-errors
}

s3_delete_object() {
  local destination="$1"

  s3_require_credentials
  aws s3api delete-object \
    --bucket "${BUCKET_NAME}" \
    --key "${destination}" \
    --endpoint-url "$(s3_endpoint_url)" \
    >/dev/null
}

s3_cp_immutable_file() {
  local source="$1"
  local destination="$2"
  local remote_copy
  local local_sha256
  local remote_sha256

  if ! s3_object_exists "${destination}"; then
    s3_cp_file "${source}" "${destination}"
    return
  fi

  remote_copy="$(mktemp)"
  s3_download_file "${destination}" "${remote_copy}"
  local_sha256="$(sha256sum "${source}" | awk '{print $1}')"
  remote_sha256="$(sha256sum "${remote_copy}" | awk '{print $1}')"
  rm -f "${remote_copy}"

  if [[ "${local_sha256}" == "${remote_sha256}" ]]; then
    log "skipping existing immutable object ${destination}; remote content matches"
    return
  fi

  die "refusing to overwrite existing immutable object with different content: ${destination}"
}
