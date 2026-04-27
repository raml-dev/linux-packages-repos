# Copyright 2026-present raml-dev
# SPDX-License-Identifier: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

APT_ROOT_DIR="${WORK_DIR}/apt"
APT_GPG_HOME="${TMP_DIR}/gnupg-apt"
APT_PUBLIC_KEY_PATH="${APT_ROOT_DIR}/raml-dev-archive-keyring.asc"
APT_ARCHITECTURES_LINE="${APT_ARCHITECTURES[*]}"

apt_require_tools() {
  command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is required for APT publication"
  command -v gzip >/dev/null 2>&1 || die "gzip is required for APT publication"
  command -v xz >/dev/null 2>&1 || die "xz is required for APT publication"
  command -v gpg >/dev/null 2>&1 || die "gpg is required for APT publication"
}

apt_packages_path() {
  local arch="$1"
  printf '%s\n' "${APT_ROOT_DIR}/dists/${APT_SUITE}/main/binary-${arch}/Packages"
}

apt_package_relative_path() {
  local arch="$1"
  printf '%s\n' "dists/${APT_SUITE}/main/binary-${arch}/Packages"
}

apt_current_pool_path() {
  local arch="$1"
  publish_context_asset_field apt "${arch}" pool_path
}

apt_download_existing_packages() {
  local arch="$1"
  local packages_path object_prefix raw_key gz_key xz_key tmp_path

  packages_path="$(apt_packages_path "${arch}")"
  object_prefix="apt/$(apt_package_relative_path "${arch}")"
  raw_key="${object_prefix}"
  gz_key="${object_prefix}.gz"
  xz_key="${object_prefix}.xz"

  mkdir -p "$(dirname "${packages_path}")"

  if s3_object_exists "${raw_key}"; then
    s3_download_file "${raw_key}" "${packages_path}"
    return
  fi

  if s3_object_exists "${gz_key}"; then
    tmp_path="${packages_path}.download.gz"
    s3_download_file "${gz_key}" "${tmp_path}"
    gzip -dc "${tmp_path}" > "${packages_path}"
    rm -f "${tmp_path}"
    return
  fi

  if s3_object_exists "${xz_key}"; then
    tmp_path="${packages_path}.download.xz"
    s3_download_file "${xz_key}" "${tmp_path}"
    xz -dc "${tmp_path}" > "${packages_path}"
    rm -f "${tmp_path}"
    return
  fi

  : > "${packages_path}"
}

apt_write_current_package_stanza() {
  local arch="$1"
  local output_path="$2"
  local package_path relative_path package_arch

  package_path="$(current_release_asset_download_path apt "${arch}")"
  relative_path="$(apt_current_pool_path "${arch}")"
  package_arch="$(dpkg_field "${package_path}" Architecture)"

  cat > "${output_path}" <<EOF
Package: $(dpkg_field "${package_path}" Package)
Version: $(dpkg_field "${package_path}" Version)
Architecture: ${package_arch}
Maintainer: $(dpkg_field "${package_path}" Maintainer)
Depends: $(dpkg_field "${package_path}" Depends)
Filename: ${relative_path}
Size: $(stat -c '%s' "${package_path}")
MD5sum: $(md5sum "${package_path}" | awk '{print $1}')
SHA1: $(sha1sum "${package_path}" | awk '{print $1}')
SHA256: $(sha256sum "${package_path}" | awk '{print $1}')
Description: $(dpkg_field "${package_path}" Description)
EOF
}

apt_filter_existing_packages() {
  local input_path="$1"
  local output_path="$2"
  local target_filename="$3"

  awk \
    -v target_filename="${target_filename}" \
    '
    BEGIN {
      RS = ""
      ORS = ""
      emitted = 0
    }
    {
      keep = 1
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "Filename: " target_filename) {
          keep = 0
          break
        }
      }
      if (keep) {
        if (emitted) {
          printf "\n\n"
        }
        printf "%s", $0
        emitted = 1
      }
    }
    END {
      if (emitted) {
        printf "\n"
      }
    }
    ' "${input_path}" > "${output_path}"
}

apt_build_packages_for_arch() {
  local arch="$1"
  local packages_path filtered_path stanza_path current_pool_path

  packages_path="$(apt_packages_path "${arch}")"
  filtered_path="${packages_path}.filtered"
  stanza_path="${packages_path}.stanza"
  current_pool_path="$(apt_current_pool_path "${arch}")"

  apt_download_existing_packages "${arch}"
  apt_filter_existing_packages "${packages_path}" "${filtered_path}" "${current_pool_path}"
  apt_write_current_package_stanza "${arch}" "${stanza_path}"

  : > "${packages_path}"
  if [[ -s "${filtered_path}" ]]; then
    cat "${filtered_path}" >> "${packages_path}"
    printf '\n' >> "${packages_path}"
  fi
  cat "${stanza_path}" >> "${packages_path}"
  printf '\n' >> "${packages_path}"

  gzip -9cn "${packages_path}" > "${packages_path}.gz"
  xz -9c "${packages_path}" > "${packages_path}.xz"
}

apt_checksum_lines() {
  local algorithm="$1"
  local suite_dir="$2"
  local file relative size digest

  find "${suite_dir}/main" -type f \( -name Packages -o -name Packages.gz -o -name Packages.xz \) | LC_ALL=C sort | while IFS= read -r file; do
    relative="${file#${suite_dir}/}"
    size="$(stat -c '%s' "${file}")"
    case "${algorithm}" in
      md5) digest="$(md5sum "${file}" | awk '{print $1}')" ;;
      sha1) digest="$(sha1sum "${file}" | awk '{print $1}')" ;;
      sha256) digest="$(sha256sum "${file}" | awk '{print $1}')" ;;
      *) die "unsupported checksum algorithm: ${algorithm}" ;;
    esac
    printf ' %s %16s %s\n' "${digest}" "${size}" "${relative}"
  done
}

write_release_file() {
  local suite_dir release_path date_value

  suite_dir="${APT_ROOT_DIR}/dists/${APT_SUITE}"
  release_path="${suite_dir}/Release"
  date_value="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"

  cat > "${release_path}" <<EOF
Origin: ${APT_ORIGIN}
Label: ${APT_LABEL}
Suite: ${APT_SUITE}
Codename: ${APT_SUITE}
Date: ${date_value}
Architectures: ${APT_ARCHITECTURES_LINE}
Components: ${APT_COMPONENT}
Description: ${APT_DESCRIPTION}
MD5Sum:
$(apt_checksum_lines md5 "${suite_dir}")
SHA1:
$(apt_checksum_lines sha1 "${suite_dir}")
SHA256:
$(apt_checksum_lines sha256 "${suite_dir}")
EOF
}

apt_import_signing_key() {
  require_env "APT_SIGNING_KEY_ASC"
  apt_require_tools
  rm -rf "${APT_GPG_HOME}"
  mkdir -p "${APT_GPG_HOME}"
  chmod 0700 "${APT_GPG_HOME}"
  printf '%s\n' "${APT_SIGNING_KEY_ASC}" | gpg --batch --homedir "${APT_GPG_HOME}" --import >/dev/null
}

apt_sign_release_file() {
  local release_path="$1"
  local inrelease_path
  local -a passphrase_args

  inrelease_path="$(dirname "${release_path}")/InRelease"
  passphrase_args=()
  if [[ -n "${APT_SIGNING_KEY_PASSPHRASE:-}" ]]; then
    passphrase_args=(--pinentry-mode loopback --passphrase "${APT_SIGNING_KEY_PASSPHRASE}")
  fi

  rm -f "${release_path}.gpg" "${inrelease_path}"

  gpg --batch --yes --homedir "${APT_GPG_HOME}" "${passphrase_args[@]}" \
    --output "${release_path}.gpg" \
    --detach-sign "${release_path}"

  gpg --batch --yes --homedir "${APT_GPG_HOME}" "${passphrase_args[@]}" \
    --output "${inrelease_path}" \
    --clearsign "${release_path}"
}

apt_export_public_key() {
  mkdir -p "${APT_ROOT_DIR}"
  gpg --batch --homedir "${APT_GPG_HOME}" --armor --export > "${APT_PUBLIC_KEY_PATH}"
}

generate_apt_metadata() {
  local arch

  rm -rf "${APT_ROOT_DIR}/dists"
  mkdir -p "${APT_ROOT_DIR}/dists/${APT_SUITE}/main"

  apt_import_signing_key

  for arch in "${APT_ARCHITECTURES[@]}"; do
    apt_build_packages_for_arch "${arch}"
  done

  write_release_file
  apt_sign_release_file "${APT_ROOT_DIR}/dists/${APT_SUITE}/Release"
  apt_export_public_key
}

publish_apt_s3() {
  local arch relative_base pool_path

  for arch in "${APT_ARCHITECTURES[@]}"; do
    pool_path="$(apt_current_pool_path "${arch}")"
    s3_cp_immutable_file \
      "$(current_release_asset_download_path apt "${arch}")" \
      "apt/${pool_path}"
  done

  for arch in "${APT_ARCHITECTURES[@]}"; do
    relative_base="$(apt_package_relative_path "${arch}")"
    s3_cp_file "$(apt_packages_path "${arch}")" "apt/${relative_base}"
    s3_cp_file "$(apt_packages_path "${arch}").gz" "apt/${relative_base}.gz"
    s3_cp_file "$(apt_packages_path "${arch}").xz" "apt/${relative_base}.xz"
  done

  s3_cp_file "${APT_ROOT_DIR}/dists/${APT_SUITE}/Release" "apt/dists/${APT_SUITE}/Release"
  s3_cp_file "${APT_ROOT_DIR}/dists/${APT_SUITE}/Release.gpg" "apt/dists/${APT_SUITE}/Release.gpg"
  s3_cp_file "${APT_ROOT_DIR}/dists/${APT_SUITE}/InRelease" "apt/dists/${APT_SUITE}/InRelease"
  s3_cp_file "${APT_PUBLIC_KEY_PATH}" "apt/raml-dev-archive-keyring.asc"
}

main() {
  prepare_work_dirs
  log "generating apt metadata..."
  generate_apt_metadata
  log "publishing apt metadata..."
  publish_apt_s3
}

main "$@"
