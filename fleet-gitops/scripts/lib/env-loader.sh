#!/usr/bin/env bash
# env-loader.sh -- Parse --env flag and source environment file
#
# Usage (source from any script after setting SCRIPT_DIR and FLEET_DIR):
#   source "${SCRIPT_DIR}/lib/env-loader.sh"
#
# After sourcing:
#   - ENV_FILE is set to the resolved path
#   - Environment variables from the file are exported
#   - --env and its value are stripped from positional parameters
#
# Behavior:
#   --env .env.rke2-test       resolves relative to FLEET_DIR
#   --env /absolute/path/.env  uses absolute path as-is
#   (no --env)                 defaults to FLEET_DIR/.env (silent skip if missing)
#   --env <missing-file>       hard error (exit 1)

# Guard: FLEET_DIR must be set by the calling script
if [[ -z "${FLEET_DIR:-}" ]]; then
  echo "[ERROR] FLEET_DIR must be set before sourcing env-loader.sh" >&2
  exit 1
fi

# Parse --env <file> from arguments
_env_loader_file="${FLEET_DIR}/.env"
_env_loader_args=()
_env_loader_skip=false
for _env_loader_arg in "$@"; do
  if [[ "${_env_loader_skip}" == true ]]; then
    _env_loader_file="${_env_loader_arg}"
    _env_loader_skip=false
    continue
  fi
  if [[ "${_env_loader_arg}" == "--env" ]]; then
    _env_loader_skip=true
    continue
  fi
  _env_loader_args+=("${_env_loader_arg}")
done
unset _env_loader_skip _env_loader_arg

# Resolve relative paths against FLEET_DIR
if [[ ! "${_env_loader_file}" = /* ]]; then
  _env_loader_file="${FLEET_DIR}/${_env_loader_file}"
fi

# Export for use by the calling script
ENV_FILE="${_env_loader_file}"
unset _env_loader_file

# Source the environment file
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
elif [[ "${ENV_FILE}" != "${FLEET_DIR}/.env" ]]; then
  echo "[ERROR] Environment file not found: ${ENV_FILE}" >&2
  exit 1
fi

# Replace positional parameters with --env stripped
set -- "${_env_loader_args[@]+"${_env_loader_args[@]}"}"
unset _env_loader_args
