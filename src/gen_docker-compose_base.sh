m4_dnl -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
m4_dnl # Copyright 2026 Northern.tech AS
m4_dnl #
m4_dnl #    Licensed under the Apache License, Version 2.0 (the "License");
m4_dnl #    you may not use this file except in compliance with the License.
m4_dnl #    You may obtain a copy of the License at
m4_dnl #
m4_dnl #        http://www.apache.org/licenses/LICENSE-2.0
m4_dnl #
m4_dnl #    Unless required by applicable law or agreed to in writing, software
m4_dnl #    distributed under the License is distributed on an "AS IS" BASIS,
m4_dnl #    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
m4_dnl #    See the License for the specific language governing permissions and
m4_dnl #    limitations under the License.

PROJECT_NAME_ALLOWED_REGEX="[^a-zA-Z0-9_-]"

show_help_and_exit_error() {
    show_help
    exit 1
}

check_dependency() {
    if ! which "$1" > /dev/null; then
        echo "The $1 utility is not found but required to generate Artifacts." >&2
        return 1
    fi
}

check_base_dependencies() {
    if ! check_dependency mender-artifact; then
        echo "Please follow the instructions here to install mender-artifact and then try again: https://docs.mender.io/downloads/workstation-tools#mender-artifact" >&2
        return 1
    fi

    if ! check_dependency skopeo; then
        echo "Please follow the instructions here to install skopeo and then try again: https://github.com/containers/skopeo" >&2
        return 1
    fi

    if ! check_dependency sha256sum; then
        echo "Please install the sha256sum utility" >&2
        return 1
    fi
}

declare -a device_types
declare -a passthrough_args
artifact_name=""
project_name=""
manifests_dir=""
images_dir=""
architecture=""
override_os=""
output_path=""
list_architectures=false

parse_base_arguments() {
    if [ $# -eq 0 ]; then
        show_help_and_exit_error
    fi

    while test $# -gt 0; do
        case "$1" in
            --project-name | -p)
                if [ -z "$2" ]; then
                    show_help_and_exit_error
                fi
                project_name="$2"
                if [[ $project_name =~ $PROJECT_NAME_ALLOWED_REGEX ]]; then
                    echo "ERROR: project name must contain only alpha-numerics, _ or -" >&2
                    show_help_and_exit_error
                fi
                shift 2
                ;;
            --manifests-dir | -m)
                if [ -z "$2" ]; then
                    show_help_and_exit_error
                fi
                manifests_dir="$2"
                shift 2
                ;;
            --images-dir | -i)
                if [ -z "$2" ]; then
                    show_help_and_exit_error
                fi
                images_dir="$2"
                shift 2
                ;;
            --device-type | -t)
                if [ -z "$2" ]; then
                    show_help_and_exit_error
                fi
                device_types+=("--compatible-types" "$2")
                shift 2
                ;;
            --artifact-name | -n)
                if [ -z "$2" ]; then
                    show_help_and_exit_error
                fi
                artifact_name=$2
                shift 2
                ;;
            --output-path | -o)
                if [ -z "$2" ]; then
                    show_help_and_exit_error
                fi
                output_path=$2
                shift 2
                ;;
            --list-architectures | -l)
                list_architectures=true
                shift 1
                ;;
            --architecture | -a)
                if [ -z "$2" ]; then
                    show_help_and_exit_error
                fi
                architecture=$2
                shift 2
                ;;
            --override-os)
                if [ -z "$2" ]; then
                    show_help_and_exit_error
                fi
                override_os=$2
                shift 2
                ;;
            -h | --help)
                show_help
                exit 0
                ;;
            --)
                shift
                passthrough_args=("$@")
                break
                ;;
            -*)
                if ! parse_extra_argument "$1" "$2"; then
                    echo "Error: unsupported option $1" >&2
                    show_help_and_exit_error
                fi
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ -z "${manifests_dir}" ]; then
        echo "Directory containing manifests not specified. Aborting." >&2
        show_help_and_exit_error
    elif ! [ -d "${manifests_dir}" ]; then
        echo "Manifests directory '${manifests_dir}' doesn't exist. Aborting." >&2
        show_help_and_exit_error
    elif [ $(ls -1 "${manifests_dir}" | wc -l) -eq 0 ]; then
        echo "Manifests directory '${manifests_dir}' needs to contain at least one manifest. Aborting." >&2
        show_help_and_exit_error
    fi
}

check_base_images() {
    images=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "${manifests_dir}"/* | sort -u)
    if [ -z "${images}" ]; then
        echo "No images found in manifests. Aborting." >&2
        show_help_and_exit_error
    fi
}

maybe_list_architectures() {
    # if true, list and exit
    if [ "$list_architectures" = true ]; then
        for image in $images; do
            archs=$(skopeo inspect --raw docker://"$image" 2> /dev/null | jq -r '([.manifests[]? | select(.platform.os == "linux") | .platform.architecture] | unique | join(","))' 2> /dev/null)
            if [ -z "$archs" ]; then
                # not a multi-arch image
                archs=$(skopeo inspect docker://"$image" 2> /dev/null | jq -r '.Architecture' 2> /dev/null)
            fi
            echo "$image: $archs"
        done
        exit 0
    fi
}

check_base_generator_args() {
    if [ -z "${artifact_name}" ]; then
        echo "Artifact name not specified. Aborting." >&2
        show_help_and_exit_error
    fi

    if [ -z "${device_types}" ]; then
        echo "Device type not specified. Aborting." >&2
        show_help_and_exit_error
    fi

    if [ -z "${project_name}" ]; then
        echo "Project name not specified. Aborting." >&2
        show_help_and_exit_error
    fi
}

temp_dir=""
init_temp_dir() {
    temp_dir="$(mktemp -d)"
    if [[ "${temp_dir}" == "" ]]; then
        echo "Cannot setup temporary directory. Aborting." >&2
        exit 1
    fi
    function cleanup() {
        if [ -n "$temp_dir" ]; then
            rm -rf "$temp_dir"
        fi
    }
    trap cleanup EXIT SIGQUIT SIGTERM
}

sha256_digest() {
    sha256sum | cut -d' ' -f1
}

dir_tree_files_digest() {
    find "$1" -mindepth 1 -type f | LC_ALL="C" sort | xargs cat | sha256_digest
}

prepare_base_images() {
    if [ -z "${images_dir}" ]; then
        mkdir $temp_dir/images
        for image in $images; do
            file_name=$(echo "$image" | tr '/:@' '_')
            echo "Downloading image: $image"
            if ! skopeo copy ${architecture:+--override-arch "$architecture"} ${override_os:+--override-os "$override_os"} docker://"$image" docker-archive:"$temp_dir/images/${file_name}.tar":"$image"; then
                echo "ERROR: Failed to download image: $image" >&2
                exit 1
            fi
        done
    elif ! [ -d "${images_dir}" ]; then
        echo "Images directory '${images_dir}' doesn't exist. Aborting." >&2
        show_help_and_exit_error
    elif [ $(ls -1 "${images_dir}" | wc -l) -eq 0 ]; then
        echo "Images directory '${images_dir}' needs to contain at least one image. Aborting." >&2
        show_help_and_exit_error
    else
        cp -r "$images_dir" "${temp_dir}/images"
    fi
}

prepare_base_manifests() {
    cp -r "$manifests_dir" "${temp_dir}/manifests"
}
