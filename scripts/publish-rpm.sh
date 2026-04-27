# Copyright 2026-present raml-dev
# SPDX-License-Identifier: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

RPM_ROOT_DIR="${WORK_DIR}/rpm"
RPM_GPG_HOME="${TMP_DIR}/gnupg-rpm"
RPM_HOME_DIR="${TMP_DIR}/rpm-home"
RPM_DB_DIR="${TMP_DIR}/rpm-db"
RPM_SIGNED_DIR="${TMP_DIR}/signed-rpms"
RPM_SIGNING_FINGERPRINT_PATH="${TMP_DIR}/rpm-signing-fingerprint"
RPM_TEMP_PUBLIC_KEY_PATH="${TMP_DIR}/rpm-public-key.asc"
RPM_PUBLIC_KEY_PATH="${RPM_ROOT_DIR}/RPM-GPG-KEY-raml-dev"
RPM_REPO_FILE_PATH="${RPM_ROOT_DIR}/raml-dev.repo"
RPM_REPOMD_HELPER="${SCRIPT_DIR}/rpm-repomd.py"
RPM_PUBLIC_BASE_URL="${REPO_PUBLIC_BASE_URL%/}"

rpm_signed_asset_path() {
  local filename="$1"
  printf '%s\n' "${RPM_SIGNED_DIR}/${filename}"
}

rpm_arch_repo_dir() {
  local arch="$1"
  printf '%s\n' "${RPM_ROOT_DIR}/stable/${arch}"
}

rpm_arch_object_prefix() {
  local arch="$1"
  printf '%s\n' "rpm/stable/${arch}"
}

rpm_repomd_path() {
  local arch="$1"
  printf '%s\n' "$(rpm_arch_repo_dir "${arch}")/repodata/repomd.xml"
}

rpm_old_hrefs_path() {
  local arch="$1"
  printf '%s\n' "${TMP_DIR}/rpm-old-hrefs-${arch}.txt"
}

rpm_location_href() {
  local arch="$1"
  local repo_path

  repo_path="$(publish_context_asset_field rpm "${arch}" repo_path)"
  case "${repo_path}" in
    stable/"${arch}"/?*)
      printf '%s\n' "${repo_path#stable/${arch}/}"
      ;;
    *)
      die "unexpected rpm repo path for ${arch}: ${repo_path}"
      ;;
  esac
}

rpm_repodata_hrefs() {
  local repomd_path="$1"
  python3 "${RPM_REPOMD_HELPER}" list-hrefs --repomd "${repomd_path}"
}

rpm_require_tools() {
  require_env "REPO_PUBLIC_BASE_URL"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for RPM publication"
  command -v rpm >/dev/null 2>&1 || die "rpm is required for RPM publication"
  command -v rpmsign >/dev/null 2>&1 || die "rpmsign is required for RPM publication"
  command -v rpmkeys >/dev/null 2>&1 || die "rpmkeys is required for RPM publication"
  command -v gpg >/dev/null 2>&1 || die "gpg is required for RPM publication"
  require_python_module "createrepo_c"
  [[ -f "${RPM_REPOMD_HELPER}" ]] || die "missing RPM repodata helper: ${RPM_REPOMD_HELPER}"
}

rpm_import_signing_key() {
  local fingerprint

  require_env "RPM_SIGNING_KEY_ASC"
  rpm_require_tools

  rm -rf "${RPM_GPG_HOME}" "${RPM_HOME_DIR}" "${RPM_DB_DIR}"
  mkdir -p "${RPM_GPG_HOME}" "${RPM_HOME_DIR}" "${RPM_DB_DIR}"
  chmod 0700 "${RPM_GPG_HOME}" "${RPM_HOME_DIR}" "${RPM_DB_DIR}"

  printf '%s\n' "${RPM_SIGNING_KEY_ASC}" | gpg --batch --homedir "${RPM_GPG_HOME}" --import >/dev/null
  fingerprint="$(gpg --batch --homedir "${RPM_GPG_HOME}" --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ -n "${fingerprint}" ]] || die "failed to determine RPM signing key fingerprint"
  printf '%s\n' "${fingerprint}" > "${RPM_SIGNING_FINGERPRINT_PATH}"

  rpm --dbpath "${RPM_DB_DIR}" --initdb >/dev/null
  gpg --batch --homedir "${RPM_GPG_HOME}" --armor --export > "${RPM_TEMP_PUBLIC_KEY_PATH}"
  rpmkeys --dbpath "${RPM_DB_DIR}" --import "${RPM_TEMP_PUBLIC_KEY_PATH}" >/dev/null

  cat > "${RPM_HOME_DIR}/.rpmmacros" <<EOF
%_signature gpg
%_gpg_name ${fingerprint}
%_gpg_path ${RPM_GPG_HOME}
%_dbpath ${RPM_DB_DIR}
%__gpg /usr/bin/gpg
EOF
}

rpm_sign_package() {
  local rpm_path="$1"
  local -a define_args

  define_args=()
  if [[ -n "${RPM_SIGNING_KEY_PASSPHRASE:-}" ]]; then
    define_args+=(--define "_gpg_sign_cmd_extra_args --pinentry-mode loopback --passphrase ${RPM_SIGNING_KEY_PASSPHRASE}")
  fi

  HOME="${RPM_HOME_DIR}" \
  GNUPGHOME="${RPM_GPG_HOME}" \
  GPG_TTY="" \
  rpmsign "${define_args[@]}" --addsign "${rpm_path}" >/dev/null
}

rpm_verify_package_signature() {
  local rpm_path="$1"
  local output

  if ! output="$(
    HOME="${RPM_HOME_DIR}" \
    GNUPGHOME="${RPM_GPG_HOME}" \
    rpm --dbpath "${RPM_DB_DIR}" -K "${rpm_path}" 2>&1
  )"; then
    log "${output}"
    die "RPM signature verification failed: ${rpm_path}"
  fi
}

rpm_export_public_key() {
  mkdir -p "${RPM_ROOT_DIR}"
  gpg --batch --homedir "${RPM_GPG_HOME}" --armor --export > "${RPM_PUBLIC_KEY_PATH}"
}

prepare_signed_current_rpm_package() {
  local arch="$1"
  local filename repo_path remote_key signed_path

  filename="$(publish_context_asset_field rpm "${arch}" filename)"
  repo_path="$(publish_context_asset_field rpm "${arch}" repo_path)"
  remote_key="rpm/${repo_path}"
  signed_path="$(rpm_signed_asset_path "${filename}")"

  mkdir -p "${RPM_SIGNED_DIR}"

  if s3_object_exists "${remote_key}"; then
    s3_download_file "${remote_key}" "${signed_path}"
    rpm_verify_package_signature "${signed_path}"
    printf '%s\n' "${signed_path}"
    return
  fi

  cp "$(current_release_asset_download_path rpm "${arch}")" "${signed_path}"
  rpm_sign_package "${signed_path}"
  rpm_verify_package_signature "${signed_path}"
  printf '%s\n' "${signed_path}"
}

rpm_download_existing_repodata_for_arch() {
  local arch="$1"
  local repo_dir repodata_dir repomd_remote_key repomd_path href old_hrefs_path

  repo_dir="$(rpm_arch_repo_dir "${arch}")"
  repodata_dir="${repo_dir}/repodata"
  repomd_path="${repodata_dir}/repomd.xml"
  repomd_remote_key="$(rpm_arch_object_prefix "${arch}")/repodata/repomd.xml"
  old_hrefs_path="$(rpm_old_hrefs_path "${arch}")"

  rm -rf "${repo_dir}"
  mkdir -p "${repodata_dir}"
  : > "${old_hrefs_path}"

  if ! s3_object_exists "${repomd_remote_key}"; then
    return
  fi

  s3_download_file "${repomd_remote_key}" "${repomd_path}"
  rpm_repodata_hrefs "${repomd_path}" > "${old_hrefs_path}"

  while IFS= read -r href; do
    [[ -n "${href}" ]] || continue
    mkdir -p "$(dirname "${repo_dir}/${href}")"
    s3_download_file "$(rpm_arch_object_prefix "${arch}")/${href}" "${repo_dir}/${href}"
  done < "${old_hrefs_path}"
}

rpm_generate_repodata_for_arch() {
  local arch="$1"
  local repo_dir repomd_path signed_path location_href
  local -a helper_repromd_arg

  repo_dir="$(rpm_arch_repo_dir "${arch}")"
  repomd_path="$(rpm_repomd_path "${arch}")"
  signed_path="$(rpm_signed_asset_path "$(publish_context_asset_field rpm "${arch}" filename)")"
  location_href="$(rpm_location_href "${arch}")"
  helper_repromd_arg=()
  if [[ -f "${repomd_path}" ]]; then
    helper_repromd_arg=(--repomd "${repomd_path}")
  fi

  python3 "${RPM_REPOMD_HELPER}" update \
    --repo-dir "${repo_dir}" \
    "${helper_repromd_arg[@]}" \
    --package-path "${signed_path}" \
    --location-href "${location_href}" \
    --output-dir "${repo_dir}/repodata"
}

rpm_sign_repomd() {
  local arch="$1"
  local repomd_path
  local -a passphrase_args

  repomd_path="$(rpm_repomd_path "${arch}")"
  [[ -f "${repomd_path}" ]] || die "missing repomd.xml for ${arch}"

  passphrase_args=()
  if [[ -n "${RPM_SIGNING_KEY_PASSPHRASE:-}" ]]; then
    passphrase_args=(--pinentry-mode loopback --passphrase "${RPM_SIGNING_KEY_PASSPHRASE}")
  fi

  rm -f "${repomd_path}.asc"
  gpg --batch --yes --homedir "${RPM_GPG_HOME}" "${passphrase_args[@]}" \
    --armor \
    --detach-sign \
    --output "${repomd_path}.asc" \
    "${repomd_path}"
}

write_rpm_repo_file() {
  cat > "${RPM_REPO_FILE_PATH}" <<EOF
[${RPM_REPO_ID}]
name=${RPM_REPO_NAME}
baseurl=${RPM_PUBLIC_BASE_URL}/rpm/stable/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=${RPM_PUBLIC_BASE_URL}/rpm/RPM-GPG-KEY-raml-dev
EOF
}

generate_rpm_metadata() {
  local arch

  rpm_import_signing_key

  for arch in "${RPM_ARCHITECTURES[@]}"; do
    prepare_signed_current_rpm_package "${arch}" >/dev/null
    rpm_download_existing_repodata_for_arch "${arch}"
    rpm_generate_repodata_for_arch "${arch}"
    rpm_sign_repomd "${arch}"
  done

  rpm_export_public_key
  write_rpm_repo_file
}

publish_rpm_s3() {
  local arch filename repo_path href old_hrefs_path

  for arch in "${RPM_ARCHITECTURES[@]}"; do
    filename="$(publish_context_asset_field rpm "${arch}" filename)"
    repo_path="$(publish_context_asset_field rpm "${arch}" repo_path)"
    old_hrefs_path="$(rpm_old_hrefs_path "${arch}")"
    s3_cp_immutable_file \
      "$(rpm_signed_asset_path "${filename}")" \
      "rpm/${repo_path}"

    while IFS= read -r href; do
      [[ -n "${href}" ]] || continue
      s3_cp_file "$(rpm_arch_repo_dir "${arch}")/${href}" "$(rpm_arch_object_prefix "${arch}")/${href}"
    done < <(rpm_repodata_hrefs "$(rpm_repomd_path "${arch}")")

    s3_cp_file "$(rpm_repomd_path "${arch}").asc" "$(rpm_arch_object_prefix "${arch}")/repodata/repomd.xml.asc"
    s3_cp_file "$(rpm_repomd_path "${arch}")" "$(rpm_arch_object_prefix "${arch}")/repodata/repomd.xml"

    if [[ -f "${old_hrefs_path}" ]]; then
      while IFS= read -r href; do
        [[ -n "${href}" ]] || continue
        if ! rpm_repodata_hrefs "$(rpm_repomd_path "${arch}")" | grep -Fxq "${href}"; then
          s3_delete_object "$(rpm_arch_object_prefix "${arch}")/${href}"
        fi
      done < "${old_hrefs_path}"
    fi
  done

  s3_cp_file "${RPM_PUBLIC_KEY_PATH}" "rpm/RPM-GPG-KEY-raml-dev"
  s3_cp_file "${RPM_REPO_FILE_PATH}" "rpm/raml-dev.repo"
}

main() {
  prepare_work_dirs
  log "generating rpm metadata..."
  generate_rpm_metadata
  log "publishing rpm metadata..."
  publish_rpm_s3
}

main "$@"
