#!/usr/bin/env bash
# Source this script so credentials remain available in your current shell.
# Usage: source ./aws-env.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'Run: source ./aws-env.sh\n' >&2
  exit 1
fi

read -r -p 'AWS access key ID: ' AWS_ACCESS_KEY_ID
read -r -s -p 'AWS secret access key: ' AWS_SECRET_ACCESS_KEY
printf '\n'

if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  printf 'Both the access key ID and secret access key are required.\n' >&2
  return 1
fi

read -r -s -p 'AWS session token (press Enter for long-term keys): ' AWS_SESSION_TOKEN
printf '\n'
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
if [[ -n "$AWS_SESSION_TOKEN" ]]; then
  export AWS_SESSION_TOKEN
else
  unset AWS_SESSION_TOKEN
fi

printf 'AWS credentials exported for this shell. Run Terraform from this directory.\n'
