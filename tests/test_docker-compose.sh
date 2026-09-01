#!/bin/bash
# Copyright 2025 Northern.tech AS
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

set -e

WORKDIR="$(mktemp -d)"
if [ -z "$WORKDIR" ]; then
    echo "Failed to create temporary workdir for tests"
    exit 1
fi
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

SRCDIR="$(dirname $0)/../src"
PERSISTENT_DIR="${WORKDIR}/persistent/mender-docker-compose"
mkdir -p "$PERSISTENT_DIR"

CMDLINE_LOGGER_LOG_FILE="${WORKDIR}/cmdline.log"

# The max timeout for a docker composition to be healhty
# Set in MENDER_DOCKER_COMPOSE_CONFIG_FILE
WAIT_TIMEOUT=2

prepare_config() {
    MENDER_DOCKER_COMPOSE_CONFIG_FILE="${WORKDIR}/mender-docker-compose.conf"
    cat << EOF > "$MENDER_DOCKER_COMPOSE_CONFIG_FILE"
PERSISTENT_STORE=${PERSISTENT_DIR}
WAIT_TIMEOUT=${WAIT_TIMEOUT}
EOF
    export MENDER_DOCKER_COMPOSE_CONFIG_FILE
}

prepare_expected_file_tree() {
    mkdir -p "${WORKDIR}/artifact-file-tree/tmp"
    mkdir "${WORKDIR}/artifact-file-tree/header"
    cat << EOF > "${WORKDIR}/artifact-file-tree/header/meta-data"
{"version": "1", "project_name": "test-comp"}
EOF
    cat << EOF > "${WORKDIR}/artifact-file-tree/header/header-info"
{
  "artifact_provides": { "artifact_name": "test-artifact" }
}
EOF
    mkdir "${WORKDIR}/artifact-file-tree/files"
    mkdir "${WORKDIR}/images"
    touch "${WORKDIR}/images/"image{1,2}.tar
    tar -C "${WORKDIR}" -czf "${WORKDIR}/artifact-file-tree/files/images.tar.gz" images
    mkdir "${WORKDIR}/manifests"
    cat << EOF > "${WORKDIR}/manifests/docker-compose.yml"
services:
  lighttpd:
    image: some/lighttpd:latest
    ports:
      - "8080:80"
  php:
    image: bad/php:oldest
EOF
    tar -C "${WORKDIR}" -cf "${WORKDIR}/artifact-file-tree/files/manifests.tar" manifests
}

cleanup_file_tree() {
    rm -rf "${WORKDIR}/artifact-file-tree"
    rm -rf "${WORKDIR}/images"
    rm -rf "${WORKDIR}/manifests"
}

prepare_docker_mock() {
    mkdir "${WORKDIR}/bin"

    # Mock docker-compose that always succeeds and just logs what it was called
    # with. We are just not interested in the discovery process.
    cat << EOF > "${WORKDIR}/bin/docker-compose"
#!/bin/bash
case "\$1" in
     --version|version)
        exit 0
        ;;
     --project-name)
        if [ "\$3" = "ps" ] && [ "\$4" = "--quiet" ]; then
            echo "fake-container-id-1"
            echo "fake-container-id-2"
            exit 0
        fi
        ;;
esac
echo "\$(basename \$0) \$@" >> "$CMDLINE_LOGGER_LOG_FILE"
exit 0
EOF
    chmod u+x "${WORKDIR}/bin/docker-compose"

    # docker: we want it to not provide the 'compose' command so the
    # docker-compose mock above handles composition commands, and we're not
    # interested in the docker compose discovery process itself. Image refs
    # are read directly from the manifest text now (see
    # get_manifest_image_refs), so no image-ID lookup mocking is needed here.
    cat << EOF > "${WORKDIR}/bin/docker"
#!/bin/bash
case "\$1" in
     --version|version)
        exit 0
        ;;
     compose)
        exit 1
        ;;
     inspect)
        shift 3
        for container_id in "\$@"; do
            echo "running:no_check"
        done
        exit 0
        ;;
esac
echo "\$(basename \$0) \$@" >> "$CMDLINE_LOGGER_LOG_FILE"
exit 0
EOF
    chmod u+x "${WORKDIR}/bin/docker"
    export PATH="${WORKDIR}/bin:${PATH}"
}

cleanup_docker_mock() {
    rm -rf "${WORKDIR}/bin"
    truncate -s0 "$CMDLINE_LOGGER_LOG_FILE"
}

declare -a tests
test_needs_reboot() {
    local output=$("${SRCDIR}/docker-compose" NeedsArtifactReboot)
    if [ "$output" != "No" ]; then
        echo "Bad output from NeedsArtifactReboot"
        return 1
    fi
    return 0
}
tests+=(test_needs_reboot)

test_supports_rollback() {
    local output=$("${SRCDIR}/docker-compose" SupportsRollback)
    if [ "$output" != "Yes" ]; then
        echo "Bad output from SupportsRollback"
        return 1
    fi
    return 0
}
tests+=(test_supports_rollback)

test_artifact_install() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp up --detach
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if ! [ -f "${PERSISTENT_DIR}/new/manifests/docker-compose.yml" ]; then
        echo "New composition doesn't exist at the expected location"
        return 1
    fi
    if ! [ -f "${PERSISTENT_DIR}/new/image_refs" ]; then
        echo "Image refs file doesn't exist at the expected location"
        return 1
    fi

    return $rc
}
tests+=(test_artifact_install)

test_artifact_install_commit() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactCommit "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactCommit failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp up --detach
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if ! [ -f "${PERSISTENT_DIR}/current/manifests/docker-compose.yml" ]; then
        echo "New composition doesn't exist at the expected location"
        return 1
    fi
    if ! [ -f "${PERSISTENT_DIR}/current/image_refs" ]; then
        echo "Image refs file doesn't exist at the expected location"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/new" ]; then
        echo "'new' directory exists after commit"
        return 1
    fi

    return $rc
}
tests+=(test_artifact_install_commit)

test_artifact_install_rollback() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactRollback "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactRollback failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp up --detach
docker-compose --project-name test-comp down
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if [ -d "${PERSISTENT_DIR}/new" ]; then
        echo "'new' directory exists after rollback and cleanup"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/current" ]; then
        echo "'current' directory exists after rollback and cleanup"
        return 1
    fi
    if ! [ -d "${PERSISTENT_DIR}/cleanup" ]; then
        echo "'cleanup' directory doesn't exists after rollback with no cleanup"
        return 1
    fi

    return $rc
}
tests+=(test_artifact_install_rollback)

test_artifact_install_rollback_cleanup() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactRollback "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactRollback failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    local image_ref1=$(head -n1 "${PERSISTENT_DIR}/cleanup/image_refs")
    local image_ref2=$(tail -n1 "${PERSISTENT_DIR}/cleanup/image_refs")
    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp up --detach
docker-compose --project-name test-comp down
docker rmi $image_ref1
docker rmi $image_ref2
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if [ -d "${PERSISTENT_DIR}/new" ]; then
        echo "'new' directory exists after rollback and cleanup"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/current" ]; then
        echo "'current' directory exists after rollback and cleanup"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/cleanup" ]; then
        echo "'cleanup' directory exists after rollback and cleanup"
        return 1
    fi

    return $rc
}
tests+=(test_artifact_install_rollback_cleanup)

test_two_artifacts_install_commit_install_commit_cleanup() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactCommit "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First ArtifactCommit failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    # Now we need to change the file tree to be a new artifact
    rm -rf "${WORKDIR}/artifact-file-tree/tmp/"*
    cat << EOF > "${WORKDIR}/artifact-file-tree/header/header-info"
{
  "artifact_provides": { "artifact_name": "test-artifact2" }
}
EOF

    rm "${WORKDIR}/images/image2.tar"
    tar -C "${WORKDIR}" -czf "${WORKDIR}/artifact-file-tree/files/images.tar.gz" images
    cat << EOF > "${WORKDIR}/manifests/docker-compose.yml"
services:
  lighttpd:
    image: some/lighttpd:latest
    ports:
      - "8081:80"
EOF
    tar -C "${WORKDIR}" -cf "${WORKDIR}/artifact-file-tree/files/manifests.tar" manifests

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Second ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactCommit "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Second ArtifactCommit failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Second Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp up --detach
docker-compose --project-name test-comp down
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker-compose --project-name test-comp up --detach
docker rmi bad/php:oldest
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if [ -d "${PERSISTENT_DIR}/new" ]; then
        echo "'new' directory exists after second commit"
        return 1
    fi
    if ! [ -d "${PERSISTENT_DIR}/current" ]; then
        echo "'current' directory doesn't exist after second commit"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/cleanup" ]; then
        echo "'cleanup' directory exists after second commit"
        return 1
    fi

    return $rc
}
tests+=(test_two_artifacts_install_commit_install_commit_cleanup)

test_two_artifacts_install_commit_install_rollback_cleanup() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactCommit "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First ArtifactCommit failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    # Now we need to change the file tree to be a new artifact
    rm -rf "${WORKDIR}/artifact-file-tree/tmp/"*
    cat << EOF > "${WORKDIR}/artifact-file-tree/header/header-info"
{
  "artifact_provides": { "artifact_name": "test-artifact2" }
}
EOF

    rm "${WORKDIR}/images/image2.tar"
    tar -C "${WORKDIR}" -czf "${WORKDIR}/artifact-file-tree/files/images.tar.gz" images
    cat << EOF > "${WORKDIR}/manifests/docker-compose.yml"
services:
  php:
    image: bad/php:worst
EOF
    tar -C "${WORKDIR}" -cf "${WORKDIR}/artifact-file-tree/files/manifests.tar" manifests

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Second ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactRollback "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactRollback failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Second Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp up --detach
docker-compose --project-name test-comp down
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker-compose --project-name test-comp up --detach
docker-compose --project-name test-comp down
docker-compose --project-name test-comp up --detach
docker rmi bad/php:worst
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if [ -d "${PERSISTENT_DIR}/new" ]; then
        echo "'new' directory exists after rollback"
        return 1
    fi
    if ! [ -d "${PERSISTENT_DIR}/current" ]; then
        echo "'current' directory doesn't exist after rollback"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/cleanup" ]; then
        echo "'cleanup' directory exists after rollback"
        return 1
    fi

    return $rc
}
tests+=(test_two_artifacts_install_commit_install_rollback_cleanup)

test_artifact_install_load_fail_rollback_cleanup() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    # We need a 'docker load' failure, ideally for the second image which is the
    # more tricky case.
    cat << EOF > "${WORKDIR}/bin/docker"
#!/bin/bash
case "\$1" in
     --version|version)
        exit 0
        ;;
     compose)
        exit 1
        ;;
     image) # docker image load --input /some/img.tar
        if [ -f "${WORKDIR}/artifact-file-tree/tmp/first_load_done" ]; then
            echo "\$(basename \$0) \$@" >> "$CMDLINE_LOGGER_LOG_FILE"
            exit 1
        else
            touch "${WORKDIR}/artifact-file-tree/tmp/first_load_done"
        fi
        ;;
     inspect)
        shift 3
        for container_id in "\$@"; do
            echo "running:no_check"
        done
        exit 0
        ;;
esac
echo "\$(basename \$0) \$@" >> "$CMDLINE_LOGGER_LOG_FILE"
exit 0
EOF

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 2 ]; then
        echo "ArtifactInstall didn't fail as expected, logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return 1
    fi
    rc=0

    "${SRCDIR}/docker-compose" ArtifactRollback "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactRollback failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    # Both refs are recorded even though loading the second image failed
    # get_manifest_image_refs reads the manifest text directly and doesn't
    # depend on the image having actually loaded.
    local image_ref1=$(head -n1 "${PERSISTENT_DIR}/cleanup/image_refs")
    local image_ref2=$(tail -n1 "${PERSISTENT_DIR}/cleanup/image_refs")
    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp down
docker rmi $image_ref1
docker rmi $image_ref2
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if [ -d "${PERSISTENT_DIR}/new" ]; then
        echo "'new' directory exists after rollback and cleanup"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/current" ]; then
        echo "'current' directory exists after rollback and cleanup"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/cleanup" ]; then
        echo "'cleanup' directory exists after rollback"
        return 1
    fi

    return $rc
}
tests+=(test_artifact_install_load_fail_rollback_cleanup)

test_artifact_install_up_fail_rollback_cleanup() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    # We need a 'docker-compose up' failure.
    cat << EOF > "${WORKDIR}/bin/docker-compose"
#!/bin/bash
case "\$1" in
     --version|version)
        exit 0
        ;;
     --project-name)
        if [ "\$3" = "ps" ] && [ "\$4" = "--quiet" ]; then
            echo "fake-container-id-1"
            echo "fake-container-id-2"
            exit 0
        fi
        ;;
esac
if [ \$3 = "up" ]; then
   echo "\$(basename \$0) \$@" >> "$CMDLINE_LOGGER_LOG_FILE"
   exit 1
fi
echo "\$(basename \$0) \$@" >> "$CMDLINE_LOGGER_LOG_FILE"
exit 0
EOF

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 1 ]; then
        echo "ArtifactInstall didn't fail as expected, logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return 1
    fi
    rc=0

    "${SRCDIR}/docker-compose" ArtifactRollback "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactRollback failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    local image_ref1=$(head -n1 "${PERSISTENT_DIR}/cleanup/image_refs")
    local image_ref2=$(tail -n1 "${PERSISTENT_DIR}/cleanup/image_refs")
    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp up --detach
docker-compose --project-name test-comp logs
docker-compose --project-name test-comp down
docker rmi $image_ref1
docker rmi $image_ref2
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if [ -d "${PERSISTENT_DIR}/new" ]; then
        echo "'new' directory exists after rollback and cleanup"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/current" ]; then
        echo "'current' directory exists after rollback and cleanup"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/cleanup" ]; then
        echo "'cleanup' directory exists after rollback"
        return 1
    fi

    return $rc
}
tests+=(test_artifact_install_up_fail_rollback_cleanup)

test_two_artifacts_install_commit_install_load_fail_rollback_cleanup() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactCommit "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First ArtifactCommit failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    # Now we need to change the file tree to be a new artifact
    rm -rf "${WORKDIR}/artifact-file-tree/tmp/"*
    cat << EOF > "${WORKDIR}/artifact-file-tree/header/header-info"
{
  "artifact_provides": { "artifact_name": "test-artifact2" }
}
EOF

    cat << EOF > "${WORKDIR}/manifests/docker-compose.yml"
services:
  lighttpd:
    image: some/lighttpd:best
    ports:
      - "8081:80"
  php:
    image: bad/php:worst
EOF
    tar -C "${WORKDIR}" -cf "${WORKDIR}/artifact-file-tree/files/manifests.tar" manifests

    # We also need a 'docker load' failure, ideally for the second image which
    # is the more tricky case.
    cat << EOF > "${WORKDIR}/bin/docker"
#!/bin/bash
case "\$1" in
     --version|version)
        exit 0
        ;;
     compose)
        exit 1
        ;;
     image) # docker image load --input /some/img.tar
        if [ -f "${WORKDIR}/artifact-file-tree/tmp/first_load_done" ]; then
            echo "\$(basename \$0) \$@" >> "$CMDLINE_LOGGER_LOG_FILE"
            exit 1
        else
            touch "${WORKDIR}/artifact-file-tree/tmp/first_load_done"
        fi
        ;;
     inspect)
        shift 3
        for container_id in "\$@"; do
            echo "running:no_check"
        done
        exit 0
        ;;
esac
echo "\$(basename \$0) \$@" >> "$CMDLINE_LOGGER_LOG_FILE"
exit 0
EOF

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 2 ]; then
        echo "Second ArtifactInstall didn't fail as expected, logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return 1
    fi
    rc=0

    "${SRCDIR}/docker-compose" ArtifactRollback "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactRollback failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Second Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    # Both the second artifact's refs get removed here, even though only
    # the first image (lighttpd:best) actually finished loading
    # neither ref matches a line in current/image_refs (which still holds the
    # first artifact's lighttpd:latest / bad/php:oldest), so both are correctly
    # identified as no longer in use.
    cat << EOF | diff -u - "$CMDLINE_LOGGER_LOG_FILE" || rc=$?
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp up --detach
docker-compose --project-name test-comp down
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image1.tar
docker image load --input ${WORKDIR}/artifact-file-tree/tmp/images/image2.tar
docker-compose --project-name test-comp down
docker-compose --project-name test-comp up --detach
docker rmi some/lighttpd:best
docker rmi bad/php:worst
EOF
    if [ $rc -ne 0 ]; then
        echo "Unexpected commands executed (see the above diff), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if [ -d "${PERSISTENT_DIR}/new" ]; then
        echo "'new' directory exists after rollback"
        return 1
    fi
    if ! [ -d "${PERSISTENT_DIR}/current" ]; then
        echo "'current' directory doesn't exist after rollback"
        return 1
    fi
    if [ -d "${PERSISTENT_DIR}/cleanup" ]; then
        echo "'cleanup' directory exists after rollback"
        return 1
    fi

    return $rc
}
tests+=(test_two_artifacts_install_commit_install_load_fail_rollback_cleanup)

test_rollback_with_previous_no_new() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" ArtifactCommit "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First ArtifactCommit failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "First Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    # Now we need to change the file tree to be a new artifact
    rm -rf "${WORKDIR}/artifact-file-tree/tmp/"*
    cat << EOF > "${WORKDIR}/artifact-file-tree/header/header-info"
{
  "artifact_provides": { "artifact_name": "test-artifact2" }
}
EOF

    rm "${WORKDIR}/images/image2.tar"
    tar -C "${WORKDIR}" -czf "${WORKDIR}/artifact-file-tree/files/images.tar.gz" images
    cat << EOF > "${WORKDIR}/manifests/docker-compose.yml"
services:
  php:
    image: bad/php:worst
EOF
    tar -C "${WORKDIR}" -cf "${WORKDIR}/artifact-file-tree/files/manifests.tar" manifests

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Second ArtifactInstall failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    # Simulate issue where artifact install fails to create 'new' directory
    # i.e. there's only 'previous'
    rm -rf "${PERSISTENT_DIR}/new"

    "${SRCDIR}/docker-compose" ArtifactRollback "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "ArtifactRollback failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi
    "${SRCDIR}/docker-compose" Cleanup "${WORKDIR}/artifact-file-tree" >> "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        echo "Second Cleanup failed (exit code $rc), logs follow:"
        cat "${WORKDIR}/docker-compose.log"
        return $rc
    fi

    if ! [ -d "${PERSISTENT_DIR}/current" ]; then
        echo "'current' directory doesn't exist after rollback"
        return 1
    fi

    return $rc
}
tests+=(test_rollback_with_previous_no_new)

test_wait_healthy_timeout() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    # Override the inspect state to return containers stuck in starting state
    sed -i 's/echo "running:no_check"/echo "running:starting"/' "${WORKDIR}/bin/docker"

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -eq 0 ]; then
        echo "ArtifactInstall should have failed with timeout"
        return 1
    fi

    if ! grep -q "Timeout reached" "${WORKDIR}/docker-compose.log"; then
        echo "Expected timeout error message not found in logs"
        cat "${WORKDIR}/docker-compose.log"
        return 1
    fi

    return 0
}
tests+=(test_wait_healthy_timeout)

test_wait_healthy_unhealthy() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    # Override the inspect state to return unhealthy containers
    sed -i 's/echo "running:no_check"/echo "running:unhealthy"/' "${WORKDIR}/bin/docker"

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -eq 0 ]; then
        echo "ArtifactInstall should have failed with unhealthy container"
        return 1
    fi

    if ! grep -q "Timeout reached" "${WORKDIR}/docker-compose.log"; then
        echo "Expected timeout error message not found in logs"
        cat "${WORKDIR}/docker-compose.log"
        return 1
    fi

    return 0
}
tests+=(test_wait_healthy_unhealthy)

test_wait_healthy_exited() {
    local rc=0

    prepare_config
    prepare_expected_file_tree
    prepare_docker_mock

    # Override the inspect state to return exited container
    sed -i 's/echo "running:no_check"/echo "exited:no_check"/' "${WORKDIR}/bin/docker"

    "${SRCDIR}/docker-compose" ArtifactInstall "${WORKDIR}/artifact-file-tree" > "${WORKDIR}/docker-compose.log" 2>&1 || rc=$?
    if [ $rc -eq 0 ]; then
        echo "ArtifactInstall should have failed with exited container"
        return 1
    fi

    if ! grep -q "Timeout reached" "${WORKDIR}/docker-compose.log"; then
        echo "Expected timeout error message not found in logs"
        cat "${WORKDIR}/docker-compose.log"
        return 1
    fi

    return 0
}
tests+=(test_wait_healthy_exited)

n_ok=0
n_fail=0
for ((i = 0; i < ${#tests[@]}; i++)); do
    echo -n "Running ${tests[$i]}... "
    if ${tests[$i]} > "${WORKDIR}/test.out" 2>&1; then
        n_ok=$((n_ok + 1))
        echo "OK"
    else
        n_fail=$((n_fail + 1))
        echo "FAIL"
        cat "${WORKDIR}/test.out"
    fi

    rm -rf "$PERSISTENT_DIR"
    cleanup_file_tree
    cleanup_docker_mock
done

echo "Total: ${#tests[@]}"
echo "Passed: ${n_ok}"
echo "Failed: ${n_fail}"
if [ $n_fail -eq 0 ]; then
    exit 0
else
    exit 1
fi

# Local Variables:
# sh-basic-offset: 4
# sh-indentation: 4
# End:
