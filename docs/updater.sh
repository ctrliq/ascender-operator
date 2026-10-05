#!/bin/sh
set -ue

requirements_in="$(readlink -f ./requirements.in)"
requirements="$(readlink -f ./requirements.txt)"
# uv resolves the same tree as pip-compile; --refresh is its -r/--rebuild, and
# unsafe packages (pip, setuptools) are emitted by default, so --allow-unsafe
# has no counterpart to carry over.
uv_compile="uv pip compile --no-strip-extras --no-header --quiet --refresh"

_cleanup() {
  cd /
  test "${KEEP_TMP:-0}" = 1 || rm -rf "${_tmp}"
  return 0
}

generate_requirements() {
  local input_reqs="$1"
  venv="$(pwd)/venv"
  echo "$venv"
  /usr/bin/python3.14 -m venv "${venv}"
  # shellcheck disable=SC1090
  source "${venv}/bin/activate"

  # pip / setuptools version must match the version used in Ascender venv (see README.md UPGRADE BLOCKERs)
  "${venv}/bin/python3" -m pip install -U 'pip==26.2.1' 'setuptools==84.0.0' uv

  ${uv_compile} ${input_reqs} --output-file requirements.txt
  return 0
}

main() {
  local command="${1:-}"
  base_dir=$(pwd)
  dest_requirements="${requirements}"
  input_requirements="${requirements_in}"

  shift || true  # Remove first argument, leave remaining as package names

  _tmp=$(python -c "import tempfile; print(tempfile.mkdtemp(suffix='.operator-requirements', dir='/tmp'))")

  trap _cleanup INT TERM EXIT

  case $command in
    "run")
      NEEDS_HELP=0
    ;;
    "upgrade")
      NEEDS_HELP=0
      if [[ $# -eq 0 ]]; then
        uv_compile="${uv_compile} --upgrade"
      else
        for package in "$@"; do
          uv_compile="${uv_compile} --upgrade-package $package"
        done
      fi
    ;;
    "outdated")
      pip list --outdated
      exit 0
    ;;
    "help")
      NEEDS_HELP=1
    ;;
    *)
      echo "" >&2
      echo "ERROR: Parameter $command not valid" >&2
      echo "" >&2
      NEEDS_HELP=1
    ;;
  esac

  if [[ "$NEEDS_HELP" == "1" ]] ; then
    echo "This script generates requirements.txt from requirements.in"
    echo ""
    echo "Usage: $0 [run|upgrade [package-name...]|outdated]"
    echo ""
    echo "Commands:"
    echo "help                   Print this message"
    echo "run                    Run the process only upgrading pinned libraries from requirements.in"
    echo "upgrade [package...]   Upgrade all libraries (or specific packages if specified) to latest while respecting pinnings"
    echo "outdated               List all outdated packages"
    echo ""
    exit
  fi

  cp -vf requirements.txt "${_tmp}"
  cd "${_tmp}"

  generate_requirements "${input_requirements}"

  echo "Changing $base_dir to /docs"
  cat requirements.txt | sed "s:$base_dir:/docs:" > "${dest_requirements}"

  _cleanup
  return 0
}

# set EVAL=1 in case you want to source this script
test "${EVAL:-0}" -eq "1" || main "$@"
