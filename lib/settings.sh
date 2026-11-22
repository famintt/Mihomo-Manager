#!/usr/bin/env bash
set -eEuo pipefail

umask 077

get_setting() {
  local key="$1"
  local default="${2:-}"
  local value
  if [ ! -e "${SETTING_FILE}" ]; then
    printf '%s' "$default"
    return 0
  fi
  validate_json_object "${SETTING_FILE}" || { print_err "设置文件损坏：${SETTING_FILE}"; return 1; }
  value="$(jq -r --arg key "$key" '.[$key] // empty' "${SETTING_FILE}")" || return 1
  printf '%s' "${value:-${default}}"
}

env_var() {
  local __env_key="$1"
  local __env_value="${!__env_key:-}"
  __env_value="${__env_value//[[:cntrl:]]/}"
  while [[ "${__env_value}" == [[:space:]]* ]]; do __env_value="${__env_value#?}"; done
  while [[ "${__env_value}" == *[[:space:]] ]]; do __env_value="${__env_value%?}"; done
  printf '%s' "${__env_value}"
}

manager_env_or_setting() {
  local _key="$1"
  local _default="${2:-}"
  local _v
  _v="$(env_var "$_key")"
  if [ -n "${_v}" ]; then
    printf '%s' "${_v}"
    return 0
  fi
  get_setting "$_key" "$_default"
}

set_setting() {
  local key="$1"
  local value="$2"
  init_storage || return 1
  # shellcheck disable=SC2016
  json_update "${SETTING_FILE}" --arg key "$key" --arg value "$value" '.[$key] = $value'
}
