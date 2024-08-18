#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

target="$( \
  tf -chdir=terraform/ show -json \
    | jq -r '.values.root_module.resources[] | select(.address == "aws_instance.app") | .values.id' \
)"
if (( "${#target}" <= 0 ))
then
  1>&2 echo 'target instance id not found'
  exit 1
fi

aws ssm start-session --target "${target}"
