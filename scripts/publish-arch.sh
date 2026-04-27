# Copyright 2026-present raml-dev
# SPDX-License-Identifier: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ARCH_ROOT_DIR="${WORK_DIR}/arch"
ARCH_GPG_HOME="${TMP_DIR}/gnupg-pacman"
ARCH_SIGNED_DIR="${TMP_DIR}/signed-arch-packages"
ARCH_SIGNING_FINGERPRINT_PATH="${TMP_DIR}/arch-signing-fingerprint"
ARCH_PUBLIC_KEY_PATH="${ARCH_ROOT_DIR}/raml-dev-pacman-key.asc"

arch_signed_asset_path() {
  local filename="$1"
  printf '%s\n' "${ARCH_SIGNED_DIR}/${filename}"
}

arch_signed_signature_path() {
  local filename="$1"
  printf '%s\n' "${ARCH_SIGNED_DIR}/${filename}.sig"
}

arch_repo_dir() {
  local arch="$1"
  printf '%s\n' "${ARCH_ROOT_DIR}/${arch}"
}

arch_require_tools() {
  command -v bsdtar >/dev/null 2>&1 || die "bsdtar is required for pacman publication"
  command -v gpg >/dev/null 2>&1 || die "gpg is required for pacman publication"
  command -v repo-add >/dev/null 2>&1 || die "repo-add is required for pacman publication"
}

arch_import_signing_key() {
  local fingerprint

  require_env "ARCH_SIGNING_KEY_ASC"
  arch_require_tools

  rm -rf "${ARCH_GPG_HOME}"
  mkdir -p "${ARCH_GPG_HOME}"
  chmod 0700 "${ARCH_GPG_HOME}"

  printf '%s\n' "${ARCH_SIGNING_KEY_ASC}" | gpg --batch --homedir "${ARCH_GPG_HOME}" --import >/dev/null
  fingerprint="$(gpg --batch --homedir "${ARCH_GPG_HOME}" --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ -n "${fingerprint}" ]] || die "failed to determine pacman signing key fingerprint"
  printf '%s\n' "${fingerprint}" > "${ARCH_SIGNING_FINGERPRINT_PATH}"
}

arch_sign_detached_file() {
  local file_path="$1"
  local output_path="$2"
  local -a passphrase_args

  passphrase_args=()
  if [[ -n "${ARCH_SIGNING_KEY_PASSPHRASE:-}" ]]; then
    passphrase_args=(--pinentry-mode loopback --passphrase "${ARCH_SIGNING_KEY_PASSPHRASE}")
  fi

  rm -f "${output_path}"
  gpg --batch --yes --homedir "${ARCH_GPG_HOME}" "${passphrase_args[@]}" \
    --detach-sign \
    --output "${output_path}" \
    "${file_path}"
}

arch_verify_detached_signature() {
  local file_path="$1"
  local sig_path="$2"

  gpg --batch --homedir "${ARCH_GPG_HOME}" --verify "${sig_path}" "${file_path}" >/dev/null 2>&1 \
    || die "pacman signature verification failed: ${file_path}"
}

arch_export_public_key() {
  mkdir -p "${ARCH_ROOT_DIR}"
  gpg --batch --homedir "${ARCH_GPG_HOME}" --armor --export > "${ARCH_PUBLIC_KEY_PATH}"
}

prepare_signed_current_arch_package() {
  local arch="$1"
  local filename repo_path remote_key signed_path sig_path

  filename="$(publish_context_asset_field arch "${arch}" filename)"
  repo_path="$(publish_context_asset_field arch "${arch}" repo_path)"
  remote_key="arch/${repo_path}"
  signed_path="$(arch_signed_asset_path "${filename}")"
  sig_path="$(arch_signed_signature_path "${filename}")"

  mkdir -p "${ARCH_SIGNED_DIR}"

  if s3_object_exists "${remote_key}" && s3_object_exists "${remote_key}.sig"; then
    s3_download_file "${remote_key}" "${signed_path}"
    s3_download_file "${remote_key}.sig" "${sig_path}"
    arch_verify_detached_signature "${signed_path}" "${sig_path}"
    printf '%s\t%s\n' "${signed_path}" "${sig_path}"
    return
  fi

  cp "$(current_release_asset_download_path arch "${arch}")" "${signed_path}"
  arch_sign_detached_file "${signed_path}" "${sig_path}"
  arch_verify_detached_signature "${signed_path}" "${sig_path}"
  printf '%s\t%s\n' "${signed_path}" "${sig_path}"
}

stage_arch_repo_packages_for_arch() {
  local arch="$1"
  local repo_dir current_filename current_signed_path current_sig_path
  local db_tar_path files_tar_path

  repo_dir="$(arch_repo_dir "${arch}")"
  current_filename="$(publish_context_asset_field arch "${arch}" filename)"
  current_signed_path="$(arch_signed_asset_path "${current_filename}")"
  current_sig_path="$(arch_signed_signature_path "${current_filename}")"
  db_tar_path="${repo_dir}/${ARCH_REPO_ID}.db.tar.gz"
  files_tar_path="${repo_dir}/${ARCH_REPO_ID}.files.tar.gz"

  rm -rf "${repo_dir}"
  mkdir -p "${repo_dir}"

  if s3_object_exists "arch/${arch}/${ARCH_REPO_ID}.db.tar.gz"; then
    s3_download_file "arch/${arch}/${ARCH_REPO_ID}.db.tar.gz" "${db_tar_path}"
  fi
  if s3_object_exists "arch/${arch}/${ARCH_REPO_ID}.files.tar.gz"; then
    s3_download_file "arch/${arch}/${ARCH_REPO_ID}.files.tar.gz" "${files_tar_path}"
  fi

  cp "${current_signed_path}" "${repo_dir}/${current_filename}"
  cp "${current_sig_path}" "${repo_dir}/${current_filename}.sig"
  arch_verify_detached_signature "${repo_dir}/${current_filename}" "${repo_dir}/${current_filename}.sig"
}

sign_arch_repo_metadata_for_arch() {
  local arch="$1"
  local repo_dir db_copy files_copy

  repo_dir="$(arch_repo_dir "${arch}")"
  db_copy="${repo_dir}/${ARCH_REPO_ID}.db"
  files_copy="${repo_dir}/${ARCH_REPO_ID}.files"

  arch_sign_detached_file "${db_copy}" "${db_copy}.sig"
  arch_sign_detached_file "${files_copy}" "${files_copy}.sig"
  arch_verify_detached_signature "${db_copy}" "${db_copy}.sig"
  arch_verify_detached_signature "${files_copy}" "${files_copy}.sig"
}

generate_arch_repo_for_arch() {
  local arch="$1"
  local repo_dir db_tar_path files_tar_path db_source_path files_source_path

  repo_dir="$(arch_repo_dir "${arch}")"
  db_tar_path="${repo_dir}/${ARCH_REPO_ID}.db.tar.gz"
  files_tar_path="${repo_dir}/${ARCH_REPO_ID}.files.tar.gz"

  rm -f \
    "${repo_dir}/${ARCH_REPO_ID}.db" \
    "${repo_dir}/${ARCH_REPO_ID}.db.sig" \
    "${repo_dir}/${ARCH_REPO_ID}.files" \
    "${repo_dir}/${ARCH_REPO_ID}.files.sig" \
    "${db_tar_path}" \
    "${files_tar_path}"

  repo-add --include-sigs "${db_tar_path}" "${repo_dir}"/*.pkg.tar.zst >/dev/null

  db_source_path="${db_tar_path}"
  files_source_path="${files_tar_path}"
  [[ -f "${db_source_path}" ]] || db_source_path="${repo_dir}/${ARCH_REPO_ID}.db"
  [[ -f "${files_source_path}" ]] || files_source_path="${repo_dir}/${ARCH_REPO_ID}.files"

  [[ -f "${db_source_path}" ]] || die "missing pacman database archive for ${arch}"
  [[ -f "${files_source_path}" ]] || die "missing pacman files archive for ${arch}"

  if [[ ! "${db_source_path}" -ef "${repo_dir}/${ARCH_REPO_ID}.db" ]]; then
    cp "${db_source_path}" "${repo_dir}/${ARCH_REPO_ID}.db"
  fi
  if [[ ! "${files_source_path}" -ef "${repo_dir}/${ARCH_REPO_ID}.files" ]]; then
    cp "${files_source_path}" "${repo_dir}/${ARCH_REPO_ID}.files"
  fi
  sign_arch_repo_metadata_for_arch "${arch}"
}

generate_arch_metadata() {
  local arch

  arch_import_signing_key

  for arch in "${ARCH_ARCHITECTURES[@]}"; do
    prepare_signed_current_arch_package "${arch}" >/dev/null
    stage_arch_repo_packages_for_arch "${arch}"
    generate_arch_repo_for_arch "${arch}"
  done

  arch_export_public_key
}

publish_arch_s3() {
  local arch filename repo_path repo_dir

  for arch in "${ARCH_ARCHITECTURES[@]}"; do
    filename="$(publish_context_asset_field arch "${arch}" filename)"
    repo_path="$(publish_context_asset_field arch "${arch}" repo_path)"
    repo_dir="$(arch_repo_dir "${arch}")"

    s3_cp_immutable_file \
      "$(arch_signed_asset_path "${filename}")" \
      "arch/${repo_path}"
    s3_cp_immutable_file \
      "$(arch_signed_signature_path "${filename}")" \
      "arch/${repo_path}.sig"

    s3_cp_file "${repo_dir}/${ARCH_REPO_ID}.db" "arch/${arch}/${ARCH_REPO_ID}.db"
    s3_cp_file "${repo_dir}/${ARCH_REPO_ID}.db.sig" "arch/${arch}/${ARCH_REPO_ID}.db.sig"
    s3_cp_file "${repo_dir}/${ARCH_REPO_ID}.db.tar.gz" "arch/${arch}/${ARCH_REPO_ID}.db.tar.gz"
    s3_cp_file "${repo_dir}/${ARCH_REPO_ID}.files" "arch/${arch}/${ARCH_REPO_ID}.files"
    s3_cp_file "${repo_dir}/${ARCH_REPO_ID}.files.sig" "arch/${arch}/${ARCH_REPO_ID}.files.sig"
    s3_cp_file "${repo_dir}/${ARCH_REPO_ID}.files.tar.gz" "arch/${arch}/${ARCH_REPO_ID}.files.tar.gz"
  done

  s3_cp_file "${ARCH_PUBLIC_KEY_PATH}" "arch/raml-dev-pacman-key.asc"
}

main() {
  prepare_work_dirs
  log "generating arch metadata..."
  generate_arch_metadata
  log "publishing arch metadata..."
  publish_arch_s3
}

main "$@"
