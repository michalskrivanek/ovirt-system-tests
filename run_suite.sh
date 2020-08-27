#!/bin/bash -ex

# Imports
source common/helpers/logger.sh
source common/helpers/python.sh
source common/helpers/ost-images.sh

CLI="lago"
DO_CLEANUP=false
RECOMMENDED_RAM_IN_MB=8196
EXTRA_SOURCES=()
RPMS_TO_INSTALL=()
COVERAGE=false
INSIDE_MOCK="$(if [ -n "${MOCK_EXTERNAL_USER}" ]; then echo 1; else echo 0; fi)"

usage () {
    echo "
Usage:

$0 [options] SUITE

This script runs a single suite of tests (a directory of tests repo)

Positional arguments:
    SUITE
        Path to directory that contains the suite to be executed

Optional arguments:
    -o,--output PATH
        Path where the new environment will be deployed.
        PATH shouldn't exist.

    -e,--engine PATH
        Path to ovirt-engine appliance iso image

    -n,--node PATH
        Path to the ovirt node squashfs iso image

    -b,--boot-iso PATH
        Path to the boot iso for node creation

    -c,--cleanup
        Clean up any generated lago workdirs for the given suite, it will
        remove also from libvirt any domains if the current lago workdir fails
        to be destroyed

    -s,--extra-rpm-source
        Extra source for rpms, any string valid for repoman will do, you can
        specify this option several times. A common example:
            -s http://jenkins.ovirt.org/job/ovirt-engine_master_build-artifacts-el7-x86_64/123

        That will take the rpms generated by that job and use those instead of
        any that would come from the reposync-config.repo file. For more
        examples visit repoman.readthedocs.io

    -r,--reposync-config
        Use a custom reposync-config file, the default is SUITE/reposync-config.repo

    -l,--local-rpms
        Install the given RPMs from Lago's internal repo.
        The RPMs are being installed on the host before any tests being invoked.
        Please note that this option WILL modify the environment it's running
        on and it requires root permissions.

    -i,--images
        Create qcow2 images of the vms that were created by the tests in SUITE

    --only-verify-requirements
        Verify that the system has the correct requirements (Disk Space, RAM, etc...)
        and exit.

    --ignore-requirements
        Don't fail if the system requirements are not satisfied.

    --coverage
        Enable coverage
"
}

on_exit() {
    [[ "$?" -ne 0 ]] && logger.error "on_exit: Exiting with a non-zero status"
    logger.info "Dumping lago env status"
    env_status || logger.error "Failed to dump env status"
}

on_sigterm() {
    local dest="${OST_REPO_ROOT}/test_logs/${SUITE##*/}/post-suite-sigterm"

    set +e
    export CLI
    export -f env_collect
    timeout \
        120s \
        bash -c "env_collect $dest"

    exit 143
}

verify_system_requirements() {
    local prefix="${1:?}"

    "${PYTHON}" "${OST_REPO_ROOT}/common/scripts/verify_system_requirements.py" \
        --prefix-path "$prefix" \
        "${SUITE}/vars/main.yml"
}

get_orb() {
    # Fetch pre made images of oVirt
    local url="${1:?}"
    local md5_url="$2"
    local archive_name && archive_name="$(basename "$url")"
    local md5_name

    [[ "$md5_url" ]] || md5_url="${url}.md5"
    md5_name="$(basename "$md5_url")"

    pushd "$SUITE"
    wget --no-clobber --progress=dot:giga "$url"
    wget "$md5_url"

    md5sum -c "$md5_name" || {
        echo "Orb image failed checksum test"
        return 1
    }
    (
        set -o pipefail
        xz -T 0 --decompress --stdout "$archive_name" \
        | tar -xv \
        || { echo "Failed to unpack Orb images"; return 1; }
    )
    popd
}

get_engine_version() {
    local root_dir="$PWD"
    cd $PREFIX
    local version=$(\
        $CLI --out-format flat ovirt status | \
        gawk 'match($0, /^global\/version:\s+(.*)$/, a) {print a[1];exit}' \
    )
    cd "$root_dir"
    echo "$version"
}

generate_vdsm_coverage_report() {
    [[ "$COVERAGE" = true ]] || return 0
    declare coverage_dir="${OST_REPO_ROOT}/coverage/vdsm"
    mkdir -p "$coverage_dir"
    "${PYTHON}" "${OST_REPO_ROOT}/common/scripts/generate_vdsm_coverage_report.py" "$PREFIX" "$coverage_dir"
}

env_init () {

    local template_repo="${1:-$SUITE/template-repo.json}"
    local initfile="${2:-$SUITE/init.json}"
    local extra_args

    if [[ -n "${OST_IMAGES_SSH_KEY}" ]]; then
        extra_args="--ssh-key ${OST_IMAGES_SSH_KEY} --skip-bootstrap"
    fi

    $CLI init \
        $PREFIX \
        "$initfile" \
        ${extra_args} \
        --template-repo-path "$template_repo"
}

put_host_image() {
    # Place a symlink to th host's base image in dest
    # The default is to place a symlink named "host_image"
    # in the internal repo.
    local internal_repo_dir="$PREFIX/current/internal_repo"
    local dest="${1:-$internal_repo_dir/host_image}"
    if [[ ! -e "$internal_repo_dir" ]]; then
        mkdir  "$internal_repo_dir"
    fi
    "${PYTHON}" "${OST_REPO_ROOT}/common/scripts/put_host_image.py" "$PREFIX" "$dest"
}

render_jinja_templates () {
    local suite_name="${SUITE##*/}"
    local src="${SUITE}/LagoInitFile.in"
    local dest="${SUITE}/LagoInitFile"

    # export the suite name so jinja can interpolate it in the template
    export suite_name="${suite_name//./-}"
    export coverage="${COVERAGE}"
    export use_ost_images="${USE_OST_IMAGES}"
    export engine_image="${OST_IMAGES_ENGINE_INSTALLED}"
    export host_image="${OST_IMAGES_HOST_INSTALLED}"
    "${PYTHON}" "${OST_REPO_ROOT}/common/scripts/render_jinja_templates.py" "$src" > "$dest"
    cat "$dest"
}

env_repo_setup () {

    local extrasrc
    declare -a extrasrcs
    cd $PREFIX
    for extrasrc in "${EXTRA_SOURCES[@]}"; do
        extrasrcs+=("--custom-source=$extrasrc")
        logger.info "Adding extra source: $extrasrc"
    done
    local reposync_conf="$SUITE/reposync-config.repo"
    if [[ -e "$CUSTOM_REPOSYNC" ]]; then
        reposync_conf="$CUSTOM_REPOSYNC"
    fi
    if [[ -n "$OST_SKIP_SYNC" ]]; then
        skipsync="--skip-sync"
    else
        skipsync=""
    fi
    logger.info "Using reposync config file: $reposync_conf"
    http_proxy="" $CLI ovirt reposetup \
        $skipsync \
        --reposync-yum-config "$reposync_conf" \
        "${extrasrcs[@]}"
    cd -
}


env_start () {

    cd $PREFIX
    $CLI start
    cd -
}

env_dump_ansible_hosts() {
    cd $PREFIX
    $CLI ansible_hosts > "${ANSIBLE_INVENTORY_FILE}"
    cd -
}

env_ovirt_start() {
    cd "$PREFIX"
    "$CLI" ovirt start
    cd -
}

env_stop () {

    cd $PREFIX
    $CLI ovirt stop
    cd -
}


env_create_images () {

    local export_dir="${PWD}/exported_images"
    local engine_version=$(get_engine_version)
    [[ -z "$engine_version" ]] && \
        logger.error "Failed to get the engine's version" && return 1
    local name="ovirt_${engine_version}_demo_$(date +%Y%m%d%H%M)"
    local archive_name="${name}.tar.xz"
    local checksum_name="${name}.md5"

    cd $PREFIX
    sleep 2 #Make sure that we can put the hosts in maintenance
    env_stop
    $CLI --out-format yaml export --dst-dir "$export_dir" --standalone
    cd -
    cd $export_dir
    echo "$engine_version" > version.txt
    "${PYTHON}" "${OST_REPO_ROOT}/common/scripts/modify_init.py" LagoInitFile
    logger.info "Compressing images"
    local files=($(ls "$export_dir"))
    tar -cvS "${files[@]}" | xz -T 0 -v --stdout > "$archive_name"
    md5sum "$archive_name" > "$checksum_name"
    cd -

}


env_deploy () {

    local res=0
    cd "$PREFIX"
    $CLI ovirt deploy || res=$?
    cd -
    return "$res"
}

env_status () {

    cd $PREFIX
    $CLI status
    cd -
}


env_run_test () {

    local res=0
    cd $PREFIX
    local junitxml_file="$PREFIX/${1##*/}.junit.xml"
    $CLI ovirt runtest $1 --junitxml-file "${junitxml_file}"  || res=$?
    [[ "$res" -ne 0 ]] && xmllint --format ${junitxml_file}
    cd -
    return "$res"
}


env_run_pytest () {

    local res=0
    cd $PREFIX
    local junitxml_file="$PREFIX/${1##*/}.junit.xml"

    "${PYTHON}" -B -m pytest \
        -s \
        -v \
        -x \
        --junit-xml="${junitxml_file}" \
        "$1" || res=$?

    [[ "$res" -ne 0 ]] && xmllint --format ${junitxml_file}
    cd -
    return "$res"
}


env_ansible () {

    # Ensure latest Ansible modules are tested:
    local collection_dir=$SUITE/collections/ansible_collections/ovirt/ovirt/plugins
    rm -rf $collection_dir/modules || true
    rm -rf $collection_dir/module_utils || true
    mkdir -p $collection_dir/modules
    mkdir -p $collection_dir/module_utils
    cd $collection_dir/modules
    ANSIBLE_URL_PREFIX="https://raw.githubusercontent.com/oVirt/ovirt-ansible-collection/master/plugins/modules/ovirt_"
    for module in vm disk cluster datacenter host network quota storage_domain template vmpool nic
    do
      OVIRT_MODULES_FILES="$OVIRT_MODULES_FILES $ANSIBLE_URL_PREFIX$module.py "
    done

    wget -N $OVIRT_MODULES_FILES
    cd -

    for module_util in ovirt cloud
    do
    wget "https://raw.githubusercontent.com/oVirt/ovirt-ansible-collection/master/plugins/module_utils/$module_util.py" -O $collection_dir/module_utils/$module_util.py
    done

    for file in $(find $collection_dir/modules/* -type f)
    do
        sed -i -e "s/@NAMESPACE@/ovirt/g" -e "s/@NAME@/ovirt/g" $file
    done

    sed -i -e "s/@NAMESPACE@/ovirt/g" -e "s/@NAME@/ovirt/g" $collection_dir/module_utils/ovirt.py
}


env_collect () {
    local tests_out_dir="${1?}"

    [[ -e "${tests_out_dir%/*}" ]] || mkdir -p "${tests_out_dir%/*}"
    cd "$PREFIX/current"
    $CLI collect --output "$tests_out_dir"
    cp -a "logs" "$tests_out_dir/lago_logs"
    cd -
}


env_cleanup() {

    local res=0
    local uuid

    logger.info "Cleaning up"
    if [[ -e "$PREFIX" ]]; then
        logger.info "Cleaning with lago"
        $CLI --workdir "$PREFIX" destroy --yes || res=$?
        [[ "$res" -eq 0 ]] && logger.success "Cleaning with lago done"
    elif [[ -e "$PREFIX/uuid" ]]; then
        uid="$(cat "$PREFIX/uuid")"
        uid="${uid:0:4}"
        res=1
    else
        logger.info "No uuid found, cleaning up any lago-generated vms"
        res=1
    fi
    if [[ "$res" -ne 0 ]]; then
        logger.info "Lago cleanup did not work (that is ok), forcing libvirt"
        env_libvirt_cleanup "${SUITE##*/}" "$uid"
    fi

    if [ ${USE_OST_IMAGES} -eq 1 -a ${INSIDE_MOCK} -eq 1 ]; then
        cleanup_ost_images
    fi

    if [ -e "$PREFIX" ]; then
        rm -r "$PREFIX"
    fi

    export LIBGUESTFS_PATH=/tmp/appliance
    rm -rf "$LIBGUESTFS_PATH"
    restore_package_manager_config
    logger.success "Cleanup done"
}


env_libvirt_cleanup() {
    local suite="${1?}"
    local uid="${2}"
    local domain
    local net
    if [[ "$uid" != "" ]]; then
        local domains=($( \
            virsh -c qemu:///system list --all --name \
            | egrep "$uid*" \
        ))
        local nets=($( \
            virsh -c qemu:///system net-list --all \
            | egrep "$uid*" \
            | awk '{print $1;}' \
        ))
    else
        local domains=($( \
            virsh -c qemu:///system list --all --name \
            | egrep "[[:alnum:]]*-lago-${suite}-" \
            | egrep -v "vdsm-ovirtmgmt" \
        ))
        local nets=($( \
            virsh -c qemu:///system net-list --all \
            | egrep -w "[[:alnum:]]{4}-.*" \
            | egrep -v "vdsm-ovirtmgmt" \
            | awk '{print $1;}' \
        ))
    fi
    logger.info "Cleaning with libvirt"
    for domain in "${domains[@]}"; do
        virsh -c qemu:///system destroy "$domain"
    done
    for net in "${nets[@]}"; do
        virsh -c qemu:///system net-destroy "$net"
    done
    logger.success "Cleaning with libvirt Done"
}


check_ram() {
    local recommended="${1:-$RECOMMENDED_RAM_IN_MB}"
    local cur_ram="$(free -m | grep Mem | awk '{print $2}')"
    if [[ "$cur_ram" -lt "$recommended" ]]; then
        logger.warning "It's recommended to have at least ${recommended}MB of RAM" \
            "installed on the system to run the system tests, if you find" \
            "issues while running them, consider upgrading your system." \
            "(only detected ${cur_ram}MB installed)"
    fi
}

get_package_manager() {
    [[ -x /bin/dnf ]] && echo dnf || echo yum
}

get_package_manager_config() {
    local pkg_manager

    pkg_manager="$(get_package_manager)"
    echo "/etc/${pkg_manager}/${pkg_manager}.conf"
}

backup_package_manager_config() {
    local path_to_config  path_to_config_bak

    path_to_config="$(get_package_manager_config)"
    path_to_config_bak="${path_to_config}.ost_bak"

    if [[ -e "$path_to_config_bak" ]]; then
        # make sure we only try to backup once
        return
    fi
    cp "$path_to_config" "$path_to_config_bak"
}

restore_package_manager_config() {
    local path_to_config  path_to_config_bak

    path_to_config="$(get_package_manager_config)"
    path_to_config_bak="${path_to_config}.ost_bak"

    if ! [[ -e "$path_to_config_bak" ]]; then
        return
    fi
    cp -f "$path_to_config_bak" "$path_to_config"
    rm "$path_to_config_bak"
}

install_local_rpms_without_reposync() {
    local pkg_manager os path_to_config

    [[ ${#RPMS_TO_INSTALL[@]} -le 0 ]] && return

    pkg_manager="$(get_package_manager)"
    path_to_config="$(get_package_manager_config)"

    os=$(rpm -E %{dist})
    os=${os#.}
    os=${os%.*}

    backup_package_manager_config

    cat > "$path_to_config" <<EOF
[internal_repo]
name=Lago's internal repo
baseurl="file://${PREFIX}/current/internal_repo/default/${os}"
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
    cat "$SUITE/reposync-config-sdk4.repo"  >> "$path_to_config"
    $pkg_manager -y install "${RPMS_TO_INSTALL[@]}" || return 1

    return 0
}

install_local_rpms() {
    local pkg_manager os path_to_config

    [[ ${#RPMS_TO_INSTALL[@]} -le 0 ]] && return

    pkg_manager="$(get_package_manager)"
    path_to_config="$(get_package_manager_config)"

    os=$(rpm -E %{dist})
    os=${os#.}
    os=${os%.*}

    backup_package_manager_config

    cat > "$path_to_config" <<EOF
[internal_repo]
name=Lago's internal repo
baseurl="file://${PREFIX}/current/internal_repo/default/${os}"
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF

    $pkg_manager -y install "${RPMS_TO_INSTALL[@]}" || return 1

    return 0
}

env_copy_config_file() {

    cd "$PREFIX"
    for vm in $(lago --out-format flat status | \
        gawk 'match($0, /^VMs\/(.*)\/status:*/, m){ print m[1]; }')\
        ; do
        # verify VM is configure

        echo "$vm"
        if [[ $(lago --out-format flat status | \
                grep "^VMs\/$vm\/metadata\/deploy-scripts:") &&
              -f "$SUITE/vars/main.yml" ]] ; then
            "$CLI" copy-to-vm "$vm" "$SUITE/vars/main.yml" "/tmp/vars_main.yml"
        fi
    done
    cd -
}

env_copy_repo_file() {
    cd "$PREFIX"
    ## declare an array variable
    declare -a vm_types_arr=("engine" "host" "storage")

    ## now loop through the above array
    for vm_type in "${vm_types_arr[@]}"
    do
        echo "$vm_type"
        local reposync_file="reposync-config-${vm_type}.repo"
        local reqsubstr="$vm_type"
        for vm in $(lago --out-format flat status | \
            gawk 'match($0, /^VMs\/(.*)\/status:*/, m){ print m[1]; }')\
            ; do

            echo "$vm"
            if [[ -f "$SUITE/$reposync_file" && -z "${vm##*$reqsubstr*}" ]] ;then
                "$CLI" copy-to-vm "$vm" "$SUITE/$reposync_file" "/etc/yum.repos.d/$reposync_file"
            fi
        done
    done

    cd -
}

install_libguestfs() {
    cd /tmp
    /var/lib/ci_toolbox/safe_download.sh \
        -s 525522aaf4fcc4f5212cc2a9e98ee873d125536e \
        appliance.lock \
        http://download.libguestfs.org/binaries/appliance/appliance-1.40.1.tar.xz \
        /var/lib/lago/appliance-1.40.1.tar.xz

    tar xvf /var/lib/lago/appliance-1.40.1.tar.xz
    cd -
    export LIBGUESTFS_PATH=/tmp/appliance
}

options=$( \
    getopt \
        -o ho:e:n:b:cs:r:l:i \
        --long help,output:,engine:,node:,boot-iso:,cleanup,images \
        --long extra-rpm-source,reposync-config:,local-rpms: \
        --long only-verify-requirements,ignore-requirements \
        --long coverage \
        -n 'run_suite.sh' \
        -- "$@" \
)
if [[ "$?" != "0" ]]; then
    exit 1
fi
eval set -- "$options"

while true; do
    case $1 in
        -o|--output)
            PREFIX=$(realpath -m $2)
            shift 2
            ;;
        -n|--node)
            NODE_ISO=$(realpath $2)
            shift 2
            ;;
        -e|--engine)
            ENGINE_OVA=$(realpath $2)
            shift 2
            ;;
        -b|--boot-iso)
            BOOT_ISO=$(realpath $2)
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -c|--cleanup)
            DO_CLEANUP=true
            shift
            ;;
        -s|--extra-rpm-source)
            EXTRA_SOURCES+=("$2")
            shift 2
            ;;
        -l|--local-rpms)
            RPMS_TO_INSTALL+=("$2")
            shift 2
            ;;
        -r|--reposync-config)
            readonly CUSTOM_REPOSYNC=$(realpath "$2")
            shift 2
            ;;
        -i|--images)
            readonly CREATE_IMAGES=true
            shift
            ;;
        --only-verify-requirements)
            readonly ONLY_VERIFY_REQUIREMENTS=true
            shift
            ;;
        --ignore-requirements)
            readonly IGNORE_REQUIREMENTS=true
            shift
            ;;
        --coverage)
            readonly COVERAGE=true
            shift
            ;;
        --)
            shift
            break
            ;;
    esac
done

if [[ -z "$1" ]]; then
    logger.error "No suite passed"
    usage
    exit 1
fi

export OST_REPO_ROOT="$PWD"

export SUITE="$(realpath --no-symlinks "$1")"

# If no deployment path provided, set the default
[[ -z "$PREFIX" ]] && PREFIX="$PWD/deployment-${SUITE##*/}"
export PREFIX

export ANSIBLE_INVENTORY_FILE="${PREFIX}/hosts"
export ANSIBLE_HOST_KEY_CHECKING="False"
export ANSIBLE_SSH_CONTROL_PATH_DIR="/tmp"

# Comment out, or set this variable to empty value, to disable debug logging
export ENABLE_DEBUG_LOGGING=debug

if "$DO_CLEANUP"; then
    env_cleanup
    exit $?
fi

[[ -e "$PREFIX" ]] && {
    echo "Failed to run OST. \
        ${PREFIX} shouldn't exist. Please remove it and retry"
    exit 1
}

mkdir -p "$PREFIX"
[[ "$IGNORE_REQUIREMENTS" ]] || verify_system_requirements "$PREFIX"
[[ $? -ne 0 ]] && { rm -rf "$PREFIX"; exit 1; }
[[ "$ONLY_VERIFY_REQUIREMENTS" ]] && { rm -rf "$PREFIX"; exit; }

[[ -d "$SUITE" ]] \
|| {
    logger.error "Suite $SUITE not found or is not a dir"
    exit 1
}

trap "on_sigterm" SIGTERM
trap "on_exit" EXIT

logger.info "Using $(lago --version 2>&1)"
logger.info "Using $(lago ovirt --version 2>&1)"

check_ram "$RECOMMENDED_RAM_IN_MB"
logger.info  "Running suite found in $SUITE"
logger.info  "Environment will be deployed at $PREFIX"

export PYTHONPATH="${PYTHONPATH}:${SUITE}"
source "${SUITE}/control.sh"

if [ ${USE_OST_IMAGES} -eq 1 -a ${INSIDE_MOCK} -eq 1 ]; then
    prepare_images_for_mock
fi

prep_suite "$ENGINE_OVA" "$NODE_ISO" "$BOOT_ISO"
run_suite
if [[ ! -z "$CREATE_IMAGES" ]]; then
    logger.info "Creating images, this might take some time..."
    env_create_images
fi
logger.success "$SUITE - All tests passed :)"
