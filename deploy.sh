#!/bin/bash

set -e

script_dir="$(dirname "$(readlink -f "$0")")"
# redefine variables from ENV to prevent SC2154
# shellcheck disable=SC2153
handler="${HANDLER}"
# shellcheck disable=SC2153
runtime="${RUNTIME}"
# shellcheck disable=SC2153
region="${REGION}"
# shellcheck disable=SC2153
name="${NAME}"
# shellcheck disable=SC2153
timeout="${TIMEOUT}"
# shellcheck disable=SC2153
role_arn="${ROLE_ARN}"
# shellcheck disable=SC2153
architectures="${ARCHITECTURES}"
# shellcheck disable=SC2153
memory_size="${MEMORY_SIZE}"
# shellcheck disable=SC1091
. "${script_dir}/functions"

arn="$(get_function_arn "${region}" "${name}")"

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
    if [[ -n "${architectures}" ]]; then
        lambda_opts+=("--architectures" "${architectures}")
    fi
    if [[ -n "${memory_size}" ]]; then
        lambda_opts+=("--memory-size" "${memory_size}")
    fi
else
    lambda_command="update-function-code"
    update="True"
fi

if [[ -n "${PUBLIC_URL}" ]]; then
    IFS=',' read -r -a envs <<<"${ENVIRONMENT_VARIABLES}"

    # shellcheck disable=SC2048,SC2086
    jo ${envs[*]} >/tmp/vars.json
    jo Variables=:/tmp/vars.json >/tmp/env.json
else
    echo "{}" >/tmp/env
fi

update=(FunctionName="${name}")
update+=(Role="${role_arn}")
update+=(Handler="${handler}")
# shellcheck disable=SC2086
update+=(Timeout=${timeout})
update+=(Environment=:/tmp/env.json)
update+=(Runtime="${runtime}")
if [[ -n "${memory_size}" ]]; then
    udate+=(MemorySize="${memory_size}")
fi

# shellcheck disable=SC2048,SC2086
jo ${update[*]} >/tmp/update.json

printf "\n\e[1;36mUploading code ...\e[0m\n\n"

### deploy code
aws \
    lambda "$lambda_command" \
    --region "${region}" \
    --function-name "${name}" \
    "${lambda_opts[@]}" \
    --zip-file fileb://"${ZIP_FILE}" | jq -e '.'

sleep 10

printf "\n\e[1;36mConfiguration ...\e[0m\n\n"

### update configuration
if [[ -n "$update" ]]; then
    aws \
        lambda update-function-configuration \
        --region "${region}" \
        --cli-input-json file:///tmp/update.json | jq -e '.'
fi

if [[ -n "${PUBLIC_URL}" ]]; then
    printf "\n\e[1;36mLambda function URL ...\e[0m\n\n"

    sleep 10

    printf "\n\e[0;36m  permissions ...\e[0m\n\n"

    ### check and add permissions if necessary
    filter='.Policy | fromjson | .Statement[] | select(.Sid=="FunctionURLAllowPublicAccess")'
    if ! permission="$(aws lambda get-policy --function-name "${name}" | jq -e "${filter}")"; then
        permission="$(aws lambda add-permission \
            --function-name "${name}" \
            --action lambda:InvokeFunctionUrl \
            --principal "*" \
            --function-url-auth-type "NONE" \
            --statement-id FunctionURLAllowPublicAccess | jq -e "${filter}")"
    fi
    jq -e '.' <<<"${permission}"

    printf "\n\e[0;36m  config ...\e[0m\n\n"

    sleep 10

    ### check existing function url config
    if ! url="$(aws lambda get-function-url-config --function-name "${name}")"; then
        ### create function url config
        url="$(aws \
            lambda create-function-url-config \
            --function-name "${name}" \
            --auth-type NONE)"
    fi
    jq -e '.' <<<"${url}"
fi
