#!/bin/bash

set -e

script_dir="$(dirname "$(readlink -f "$0")")"
# redefine variables from ENV to prevent SC2154
# shellcheck disable=SC2269
region="${region}"
# shellcheck disable=SC2269,SC2153
function_name="${FUNCTION_NAME}"
# shellcheck disable=SC1091
. "${script_dir}/functions"

arn="$(get_function_arn "${region}" "${function_name}")"

printf "\n\e[1;36mPreparing upload ...\e[0m\n\n"

### prepare deployment
if [[ -z "$arn" ]]; then
    lambda_command="create-function"
    lambda_opts=(
        "--runtime" "${runtime}"
        "--role" "${role_arn}"
        "--handler" "${handler}"
        "--timeout" "${timeout:-30}"
    )
else
    lambda_command="update-function-code"
    update="True"
fi

IFS=',' read -r -a envs <<<"${ENVIRONMENT_VARIABLES}"

# shellcheck disable=SC2048,SC2086
jo ${envs[*]} >/tmp/env

# shellcheck disable=SC2086
jo \
    FunctionName="${function_name}" \
    Role="${role_arn}" \
    Handler="${handler}" \
    Timeout=${timeout} \
    Environment=:/tmp/env \
    Runtime="${runtime}" \
    >/tmp/update.json

printf "\n\e[1;36mUploading code ...\e[0m\n\n"

### deploy code
aws \
    lambda "$lambda_command" \
    --region "${region}" \
    --function-name "${function_name}" \
    "${lambda_opts[@]}" \
    --zip-file fileb://"${ZIP_FILE}" | jq '.'

sleep 5

printf "\n\e[1;36mConfiguration ...\e[0m\n\n"

### update configuration
if [[ -n "$update" ]]; then
    aws \
        lambda update-function-configuration \
        --region "${region:-eu-central-1}" \
        --cli-input-json file:///tmp/update.json | jq '.'
fi

if [[ -n "${PUBLIC_URL}" ]]; then
    printf "\n\e[1;36mLambda function URL ...\e[0m\n\n"

    printf "\n\e[0;36m  permissions ...\e[0m\n\n"

    ### check and add permissions if necessary
    filter='.Policy | fromjson | .Statement[] | select(.Sid=="FunctionURLAllowPublicAccess")'
    if ! permission="$(aws lambda get-policy --function-name "${function_name}" | jq -e "${filter}")"; then
        permission="$(aws lambda add-permission \
            --function-name "${function_name}" \
            --action lambda:InvokeFunctionUrl \
            --principal "*" \
            --function-url-auth-type "NONE" \
            --statement-id FunctionURLAllowPublicAccess | jq "${filter}")"
    fi
    jq '.' <<<"${permission}"

    printf "\n\e[0;36m  config ...\e[0m\n\n"
    ### check existing function url config
    if ! url="$(aws lambda get-function-url-config --function-name "${function_name}")"; then
        ### create function url config
        url="$(aws \
            lambda create-function-url-config \
            --function-name "${function_name}" \
            --auth-type NONE)"
    fi
    jq '.' <<<"${url}"
fi
