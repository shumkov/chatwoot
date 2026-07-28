#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

die() {
  printf 'UMI FB/IG program: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  sha256sum --binary "$1" | awk '{ print $1 }'
}

require_safe_token() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[a-zA-Z0-9._:@/+,-]+$ ]] ||
    die "$name contains unsupported characters"
}

require_trusted_ancestors() {
  local path="$1"
  local canonical
  local current
  local mode

  [[ "$path" = /* && -e "$path" ]] || die "path is missing or not absolute: $path"
  canonical="$(
    python3 - "$path" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
  )"
  [[ "$canonical" = "$path" ]] || die "path is not canonical and link-free: $path"
  current="$(dirname "$path")"
  while [[ "$current" != / ]]; do
    [[ -d "$current" && ! -L "$current" ]] ||
      die "path ancestor is not a regular directory: $current"
    [[ "$(stat -Lc '%u:%g' "$current")" = '0:0' ]] ||
      die "path ancestor must be root-owned: $current"
    mode="$(stat -Lc '%a' "$current")"
    (( (8#$mode & 8#022) == 0 )) ||
      die "path ancestor must not be group/world writable: $current"
    current="$(dirname "$current")"
  done
}

require_trusted_directory() {
  local path="$1"
  local mode

  [[ -d "$path" && ! -L "$path" ]] || die "directory is missing or not regular: $path"
  require_trusted_ancestors "$path"
  [[ "$(stat -Lc '%u:%g' "$path")" = '0:0' ]] ||
    die "directory must be root-owned: $path"
  mode="$(stat -Lc '%a' "$path")"
  (( (8#$mode & 8#022) == 0 )) ||
    die "directory must not be group/world writable: $path"
}

require_new_root_directory_path() {
  local path="$1"
  local canonical
  local parent

  [[ "$path" = /* && ! -e "$path" && ! -L "$path" ]] ||
    die "new directory path is not absolute or already exists: $path"
  canonical="$(
    python3 - "$path" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
  )"
  [[ "$canonical" = "$path" ]] || die "path is not canonical and link-free: $path"
  parent="$(dirname "$path")"
  require_trusted_directory "$parent"
}

require_new_root_subdirectory_path() {
  local path="$1"
  local parent="$2"
  local canonical

  [[ "$(dirname "$path")" = "$parent" ]] ||
    die "new subdirectory is not directly below its expected parent: $path"
  require_new_root_directory_path "$parent"
  [[ "$path" = /* && ! -e "$path" && ! -L "$path" ]] ||
    die "new subdirectory path is not absolute or already exists: $path"
  canonical="$(
    python3 - "$path" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
  )"
  [[ "$canonical" = "$path" ]] || die "path is not canonical and link-free: $path"
}

require_root_directory() {
  local path="$1"
  require_trusted_directory "$path"
  [[ "$(stat -Lc '%u:%g:%a' "$path")" = '0:0:700' ]] ||
    die "directory must be root:root mode 0700: $path"
}

require_root_readonly_file() {
  local path="$1"
  local attributes
  local owner
  local group
  local mode

  [[ -f "$path" && ! -L "$path" ]] || die "file is missing or not regular: $path"
  require_trusted_ancestors "$path"
  attributes="$(stat -Lc '%u:%g:%a:%h' "$path")"
  IFS=: read -r owner group mode links <<<"$attributes"
  [[ "$owner" = 0 && "$group" = 0 && "$links" = 1 ]] ||
    die "file must be root:root with one link: $path"
  (( (8#$mode & 8#022) == 0 )) || die "file must not be group/world writable: $path"
}

require_root_artifact() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || die "artifact is missing or not regular: $path"
  require_trusted_ancestors "$path"
  [[ "$(stat -Lc '%u:%g:%a:%h' "$path")" = '0:0:400:1' ]] ||
    die "artifact must be root:root mode 0400 with one link: $path"
}

verify_checksum() {
  local artifact="$1"
  local checksum="$2"
  local generated

  require_root_artifact "$artifact"
  require_root_artifact "$checksum"
  generated="$(mktemp)"
  printf '%s  %s\n' "$(sha256_file "$artifact")" "$(basename "$artifact")" >"$generated"
  cmp -s "$generated" "$checksum" || {
    rm -f "$generated"
    die "checksum mismatch: $artifact"
  }
  rm -f "$generated"
}

publish_artifact() {
  local temporary="$1"
  local artifact="$2"
  local checksum="${artifact}.sha256"
  local checksum_temporary

  [[ "$(dirname "$temporary")" = "$(dirname "$artifact")" ]] ||
    die "artifact temporary file must share its destination directory"
  [[ -f "$temporary" && ! -L "$temporary" ]] || die "artifact temporary file is invalid"
  [[ ! -e "$artifact" && ! -e "$checksum" ]] || die "artifact already exists: $artifact"
  chmod 0400 "$temporary"
  fsync_path "$temporary"
  ln "$temporary" "$artifact"
  rm -f "$temporary"
  fsync_path "$(dirname "$artifact")"
  checksum_temporary="${checksum}.$$.tmp"
  (
    set -o noclobber
    printf '%s  %s\n' "$(sha256_file "$artifact")" "$(basename "$artifact")" >"$checksum_temporary"
  )
  chmod 0400 "$checksum_temporary"
  fsync_path "$checksum_temporary"
  ln "$checksum_temporary" "$checksum"
  rm -f "$checksum_temporary"
  fsync_path "$(dirname "$artifact")"
  verify_checksum "$artifact" "$checksum"
}

seal_in_place() {
  local artifact="$1"
  local checksum="${artifact}.sha256"
  local checksum_temporary

  if [[ -e "$checksum" ]]; then
    verify_checksum "$artifact" "$checksum"
    return
  fi
  require_root_readonly_file "$artifact"
  chmod 0400 "$artifact"
  fsync_path "$artifact"
  checksum_temporary="${checksum}.$$.tmp"
  (
    set -o noclobber
    printf '%s  %s\n' "$(sha256_file "$artifact")" "$(basename "$artifact")" >"$checksum_temporary"
  )
  chmod 0400 "$checksum_temporary"
  fsync_path "$checksum_temporary"
  ln "$checksum_temporary" "$checksum"
  rm -f "$checksum_temporary"
  fsync_path "$(dirname "$artifact")"
  verify_checksum "$artifact" "$checksum"
}

require_ordered_manifest() {
  local path="$1"
  shift
  local expected=("$@")
  local rows=()
  local index

  awk -F '\t' '
    NF != 2 || $1 !~ /^[a-z0-9_]+$/ || $2 == "" { exit 1 }
  ' "$path" || die "malformed manifest: $path"
  mapfile -t rows <"$path"
  [[ "${#rows[@]}" -eq "${#expected[@]}" ]] ||
    die "wrong manifest row count: $path"
  for index in "${!expected[@]}"; do
    [[ "${rows[$index]%%$'\t'*}" = "${expected[$index]}" ]] ||
      die "wrong manifest field order: $path"
  done
}

manifest_value() {
  local path="$1"
  local key="$2"
  awk -F '\t' -v key="$key" '
    $1 == key {
      count += 1
      value = $2
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$path" || die "missing or duplicate manifest field $key: $path"
}

stage_value() {
  local path="$1"
  local stage="$2"
  local key="$3"
  awk -v expected_stage="$stage" -v expected_key="$key" '
    {
      current_stage = ""
      found = 0
      value = ""
      for (field = 1; field <= NF; field += 1) {
        split($field, pair, "=")
        if (pair[1] == "stage") current_stage = pair[2]
        if (pair[1] == expected_key) {
          found += 1
          value = pair[2]
        }
      }
      if (current_stage == expected_stage && found == 1) {
        matches += 1
        result = value
      }
    }
    END {
      if (matches != 1) exit 1
      print result
    }
  ' "$path" || die "missing or ambiguous $stage.$key: $path"
}

verify_seed_target_conservation() {
  local log="$1"
  local summary="$2"
  local platforms
  local expected
  local seed_targets
  local seed_targets_complete
  local seed_targets_success
  local seed_targets_unavailable
  local seed_targets_blocking
  local seed_targets_repaired
  local seed_targets_preserved
  local seed_targets_blank_name
  local seed_targets_blocked
  local value

  platforms="$(stage_value "$log" history_profiles_start platforms)"
  expected="$(stage_value "$log" history_profiles_start seed_targets_expected)"
  [[ "$expected" =~ ^[0-9]+$ ]]
  if [[ ",$platforms," = *,instagram,* ]]; then
    test "$expected" -gt 0
  else
    test "$platforms" = messenger
    test "$expected" = 0
  fi

  seed_targets="$(stage_value "$summary" history_profiles_summary seed_targets)"
  seed_targets_complete="$(
    stage_value "$summary" history_profiles_summary seed_targets_complete
  )"
  seed_targets_success="$(
    stage_value "$summary" history_profiles_summary seed_targets_success
  )"
  seed_targets_unavailable="$(
    stage_value "$summary" history_profiles_summary seed_targets_unavailable
  )"
  seed_targets_blocking="$(
    stage_value "$summary" history_profiles_summary seed_targets_blocking
  )"
  seed_targets_repaired="$(
    stage_value "$summary" history_profiles_summary seed_targets_repaired
  )"
  seed_targets_preserved="$(
    stage_value "$summary" history_profiles_summary seed_targets_preserved
  )"
  seed_targets_blank_name="$(
    stage_value "$summary" history_profiles_summary seed_targets_blank_name
  )"
  seed_targets_blocked="$(
    stage_value "$summary" history_profiles_summary seed_targets_blocked
  )"
  for value in \
    "$seed_targets" "$seed_targets_complete" "$seed_targets_success" \
    "$seed_targets_unavailable" "$seed_targets_blocking" \
    "$seed_targets_repaired" "$seed_targets_preserved" \
    "$seed_targets_blank_name" "$seed_targets_blocked"; do
    [[ "$value" =~ ^[0-9]+$ ]]
  done

  test "$seed_targets" = "$expected"
  test "$seed_targets_complete" = "$expected"
  test "$expected" -eq \
    "$((seed_targets_success + seed_targets_unavailable + seed_targets_blocking))"
  test "$expected" -eq \
    "$((seed_targets_repaired + seed_targets_preserved + seed_targets_blank_name + seed_targets_unavailable + seed_targets_blocked))"
  test "$seed_targets_blocking" = "$seed_targets_blocked"
}

fsync_path() {
  python3 - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
flags = os.O_RDONLY
if os.path.isdir(path):
    flags |= getattr(os, "O_DIRECTORY", 0)
descriptor = os.open(path, flags)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

publish_directory_no_replace() {
  python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

source_path = os.fsencode(sys.argv[1])
destination = os.fsencode(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = [
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
]
renameat2.restype = ctypes.c_int
if renameat2(-100, source_path, -100, destination, 1) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), sys.argv[2])
PY
}

acquire_descriptor_verified_lock() {
  local lock_path="$1"
  local path_identity
  local descriptor_identity

  require_root_directory "$(dirname "$lock_path")"
  if [[ -e "$lock_path" ]]; then
    [[ -f "$lock_path" && ! -L "$lock_path" ]] || die "invalid lock artifact"
    [[ "$(stat -Lc '%u:%g:%a:%h' "$lock_path")" = '0:0:600:1' ]] ||
      die "lock must be root:root mode 0600 with one link"
  fi
  exec {UMI_FBIG_LOCK_FD}>"$lock_path"
  chmod 0600 "$lock_path"
  path_identity="$(stat -Lc '%d:%i' "$lock_path")"
  descriptor_identity="$(stat -Lc '%d:%i' "/proc/self/fd/$UMI_FBIG_LOCK_FD")"
  [[ "$path_identity" = "$descriptor_identity" ]] || die "lock descriptor identity mismatch"
  flock -x "$UMI_FBIG_LOCK_FD"
  [[ "$(stat -Lc '%d:%i' "$lock_path")" = "$descriptor_identity" ]] ||
    die "lock path changed while acquiring descriptor"
}
