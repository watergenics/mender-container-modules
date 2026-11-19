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

JQ_CMD="jq"
TAR_CMD="tar"
DOCKER_CMD="docker"
DOCKER_COMPOSE_CMD=""

discover_docker_compose() {
    local rc=0

    if test -n "$DOCKER_COMPOSE_CMD"; then
        $DOCKER_COMPOSE_CMD version < /dev/null > /dev/null 2>&1
        rc=$?
    elif $DOCKER_CMD compose version < /dev/null > /dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="$DOCKER_CMD compose"
    elif docker-compose version < /dev/null > /dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo "ERROR: could not find executable for Docker Compose" 1>&2
        echo "ERROR: is Docker Compose installed?" 1>&2
        rc=1
    fi

    return $rc
}

discover_base_requirements() {
    local rc=0

    if ! $JQ_CMD --version > /dev/null 2>&1; then
        echo "ERROR: $JQ_CMD is required. Exiting."
        rc=1
    fi
    if ! $TAR_CMD --version < /dev/null > /dev/null 2>&1; then
        echo "ERROR: $TAR_CMD is required. Exiting."
        rc=1
    fi
    if ! $DOCKER_CMD --version > /dev/null < /dev/null 2>&1; then
        echo "ERROR: cannot find command \"${DOCKER_CMD}\" in PATH"
        echo "ERROR: is Docker installed?"
        rc=1
    fi
    if ! $DOCKER_CMD version > /dev/null; then
        echo "ERROR: failed to connect with the Docker API"
        rc=1
    fi
    discover_docker_compose || rc=1

    return $rc
}

parse_metadata() {
    # $1 -- meta-data JSON file
    # $2 -- header-info JSON file

    PROJECT_NAME=$(jq -r .project_name < "$1")
    version=$(jq -r .version < "$1")
    ARTIFACT_NAME=$(jq -r .artifact_provides.artifact_name < "$2")

    if [ "${PROJECT_NAME}" = "" ] || [ "${PROJECT_NAME}" = "null" ]; then
        echo "ERROR: project_name is required in meta-data. Exiting."
        return 1
    fi

    if test "${version}" = ""; then
        echo "ERROR: version is required in meta-data. Exiting."
        return 1
    elif test "${version}" != "1"; then
        echo "ERROR: only version 1 is supported, not version ${version}. Exiting."
        return 1
    fi

    if test "${ARTIFACT_NAME}" = ""; then
        echo "ERROR: artifact_name is required. Exiting."
        return 1
    fi
}

container_image_load() {
    local input_file="$1"

    $DOCKER_CMD image load --input "$input_file"
}

comp_stop() {
    local manifests_dir="$1/manifests"
    local project_name=$(cat "$1/project_name")
    local rc=0

    echo "Stopping $1"
    (
        cd "$manifests_dir"
        $DOCKER_COMPOSE_CMD \
            --project-name "$project_name" \
            down >> ../compose.log 2>&1
    ) || rc=$?

    if test "$rc" -ne 0; then
        echo "Failed to stop composition, logs follow:" 1>&2
        cat "$manifests_dir/../compose.log" 1>&2
        (
            cd "$manifests_dir"
            $DOCKER_COMPOSE_CMD \
                --project-name "$project_name" \
                logs 1>&2
        )
        return $rc
    fi

    return 0
}

# For docker compose 2.0 and onwards you can use `--wait` and `--wait-timeout`
# In order to not break backwards compatibility we use our own
# logic to check if the containers started by a composition are healthy
wait_healthy() {
    local project_name="$1"
    local manifests_dir="$2"
    local timeout="$WAIT_TIMEOUT"
    local states

    while [ "$timeout" -gt 0 ]; do
        local container_ids=$(
            cd "$manifests_dir" \
                                && $DOCKER_COMPOSE_CMD --project-name "$project_name" ps --quiet
        )
        if [ -n "$container_ids" ]; then
            states=$($DOCKER_CMD inspect --format '{{.State.Status}}:{{if .State.Health}}{{.State.Health.Status}}{{else}}no_check{{end}}' $container_ids 2> /dev/null)
            local not_ready_count=$(echo "$states" | grep -v -E "^running:(healthy|no_check)$" | wc -l)
            if [ "$not_ready_count" -eq 0 ]; then
                return 0
            fi
        fi
        sleep 1
        timeout=$((timeout - 1))
    done

    echo "Timeout reached. Some containers are not healthy/running." 1>&2
    echo "Container states at timeout:" 1>&2
    echo "$states" 1>&2
    return 1
}

comp_start() {
    local manifests_dir="$1/manifests"
    local project_name=$(cat "$1/project_name")
    local rc=0

    echo "Starting $1"
    (
        cd "$manifests_dir"
        $DOCKER_COMPOSE_CMD \
            --project-name "$project_name" \
            up --detach > ../compose.log 2>&1
    ) || rc=$?

    if test "$rc" -eq 0; then
        wait_healthy "$project_name" "$manifests_dir" || rc=$?
    fi

    if test "$rc" -ne 0; then
        echo "Failed to start composition, logs follow:" 1>&2
        cat "$manifests_dir/../compose.log" 1>&2
        (
            cd "$manifests_dir"
            $DOCKER_COMPOSE_CMD \
                --project-name "$project_name" \
                logs 1>&2
        )
    fi
    return "$rc"
}

get_manifest_image_ids() {
    local manifest="$1"
    local id

    local image
    for image in $(grep -E "^\s+image:" "$manifest" | cut -d: -f2-); do
        id=$($DOCKER_CMD images --format "{{json .ID}}" "$image" | head -n1 | tr -d '"')
        if [ -n "$id" ]; then
            echo "$image $id"
        fi
    done
}

# Re-applies the tags recorded in a composition's image_ids file to the image
# IDs they were originally recorded against. This is necessary because loading
# a newer artifact's images can move a tag (e.g. "myimage:latest") over to the
# newly loaded image, so the previous composition's tags no longer point at
# the images it actually needs when we roll back to it.
retag_composition_images() {
    local composition_dir="$1"
    local image_ids_file="${composition_dir}/image_ids"

    if [ ! -f "$image_ids_file" ]; then
        return 0
    fi

    local image_ref image_id
    while read -r image_ref image_id; do
        # Compositions installed by an older version of this script only
        # recorded the image ID, without the tag, in this file. Skip those
        # entries, there's nothing to retag them from.
        if [ -z "$image_id" ]; then
            continue
        fi
        $DOCKER_CMD tag "$image_id" "$image_ref"
    done < "$image_ids_file"
}

install_composition_from_artifact() {
    local artifact_files="$1"
    local rc=0

    if test -d "${PERSISTENT_STORE}/current"; then
        echo "saving existing composition as -previous"
        rm -rf "${PERSISTENT_STORE}/previous" # should not be there, but just in case
        mv -v "${PERSISTENT_STORE}/current" "${PERSISTENT_STORE}/previous"
    else
        echo "no previous composition found"
    fi

    # If the previous version is present, we need to make sure it's stopped.
    # XXX: let docker compose figure this out?
    if test -d "${PERSISTENT_STORE}/previous"; then
        comp_stop "${PERSISTENT_STORE}/previous"
    else
        echo "previous composition not present; nothing to stop."
    fi

    if test ! -d "$TEMP_DIR"; then
        echo "ERROR: $TEMP_DIR does not exist"
        return 1
    fi

    if ! extract_images_from_artifact "$artifact_files"; then
        echo "ERROR: failed to extra images from artifact"
        return 1
    fi

    echo "extracting manifests"
    $TAR_CMD -xf "${artifact_files}/manifests.tar" -C "$TEMP_DIR"

    mkdir -p "${PERSISTENT_STORE}/current"
    cp -r "${TEMP_DIR}/manifests" "${PERSISTENT_STORE}/current/"
    echo "${PROJECT_NAME}" > "${PERSISTENT_STORE}/current/project_name"
    touch "${PERSISTENT_STORE}/uncommitted"

    local image
    for image in "${TEMP_DIR}/images/"*; do
        if ! container_image_load "$image"; then
            # Make sure to gather the IDs of loaded images below for cleanup.
            rc=2
            break
        fi
    done

    local manifest
    for manifest in "${PERSISTENT_STORE}/current/manifests/"*; do
        test -f "$manifest" || continue
        get_manifest_image_ids "$manifest" >> "${PERSISTENT_STORE}/current/image_ids"
    done
    # multiple services can use the same image
    # cleanup() and retag_composition_images() need to handle each image once
    # to avoid the update to return with an error
    # preserves manifest ordering
    if [ -f "${PERSISTENT_STORE}/current/image_ids" ]; then
        awk '!seen[$0]++' "${PERSISTENT_STORE}/current/image_ids" > "${PERSISTENT_STORE}/current/image_ids.tmp"
        mv "${PERSISTENT_STORE}/current/image_ids.tmp" "${PERSISTENT_STORE}/current/image_ids"
    fi
    if [ $rc -ne 0 ]; then
        return $rc
    fi

    comp_start "${PERSISTENT_STORE}/current" 2>&1
}

commit_artifact() {
    rm -f "${PERSISTENT_STORE}/uncommitted"
    if [ -d "${PERSISTENT_STORE}/previous" ]; then
        mv -v "${PERSISTENT_STORE}/previous" "${PERSISTENT_STORE}/cleanup"
    fi
}

rollback_composition_from_artifact() {
    if [ ! -f "${PERSISTENT_STORE}/uncommitted" ] && [ ! -d "${PERSISTENT_STORE}/previous" ]; then
        if test -d "${PERSISTENT_STORE}/current"; then
            # This may seem weird (and it is!), but rollback can be requested even
            # after a commit. In that case we rollback from the committed version to
            # the one pushed for cleanup.
            echo "Rolling back after a Commit"

            # Let's set the stage for the rest of this function.
            if [ -d "${PERSISTENT_STORE}/cleanup" ]; then
                mv -v "${PERSISTENT_STORE}/cleanup" "${PERSISTENT_STORE}/previous"
            fi
        else
            echo "Nothing to rollback to!"
            return 1
        fi
    fi

    rm -f "${PERSISTENT_STORE}/uncommitted"

    if [ -d "${PERSISTENT_STORE}/current" ]; then
        # Stopping may fail in case starting failed which we don't know.
        comp_stop "${PERSISTENT_STORE}/current" || true
        mv -v "${PERSISTENT_STORE}/current" "${PERSISTENT_STORE}/cleanup"
    fi

    if [ -d "${PERSISTENT_STORE}/previous" ]; then
        mv -v "${PERSISTENT_STORE}/previous" "${PERSISTENT_STORE}/current"
        retag_composition_images "${PERSISTENT_STORE}/current"
        comp_start "${PERSISTENT_STORE}/current" 2>&1
    else
        echo "No previous composition to roll back to"
    fi

    return 0
}

cleanup() {
    local rc=0

    if ! test -d "${PERSISTENT_STORE}/cleanup"; then
        return 0
    fi

    if test -f "${PERSISTENT_STORE}/cleanup/image_ids"; then
        local image_ref image_id
        while read -r image_ref image_id; do
            # Compositions installed by an older version of this script only
            # recorded the image ID, without the tag, in this file.
            if [ -z "$image_id" ]; then
                image_id="$image_ref"
            fi
            # $NF is the last field, i.e. the image ID regardless of whether
            # the line also has a tag as its first field (new format) or not
            # (old format).
            if ! awk '{print $NF}' "${PERSISTENT_STORE}/current/image_ids" 2> /dev/null | grep -qFx "$image_id"; then
                $DOCKER_CMD rmi --force "$image_id" || rc=1
            fi
        done < "${PERSISTENT_STORE}/cleanup/image_ids"
    fi
    rm -rf "${PERSISTENT_STORE}/cleanup"

    return $rc
}
