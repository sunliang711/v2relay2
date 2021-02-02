#!/bin/bash
if [ -z "${BASH_SOURCE}" ]; then
    this=${PWD}
else
    rpath="$(readlink ${BASH_SOURCE})"
    if [ -z "$rpath" ]; then
        rpath=${BASH_SOURCE}
    fi
    this="$(cd $(dirname $rpath) && pwd)"
fi

export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

rootID=0

# export TERM=xterm-256color

# Use colors, but only if connected to a terminal, and that terminal
# supports them.
if which tput >/dev/null 2>&1; then
    ncolors=$(tput colors 2>/dev/null)
fi
if [ -t 1 ] && [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 5)"
    BOLD="$(tput bold)"
    NORMAL="$(tput sgr0)"
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    BLUE=""
    BOLD=""
    NORMAL=""
fi
_err() {
    echo "$*" >&2
}

_runAsRoot() {
    cmd="${*}"
    if [ "${EUID}" -ne "${rootID}" ]; then
        echo -n "Not root, try to run as root.."
        # or sudo sh -c ${cmd} ?
        if eval "sudo ${cmd}"; then
            echo "ok"
            return 0
        else
            echo "failed"
            return 1
        fi
    else
        # or sh -c ${cmd} ?
        eval "${cmd}"
    fi
}

function _root() {
    if [ ${EUID} -ne ${rootID} ]; then
        echo "Need run as root!"
        exit 1
    fi
}

ed=vi
if command -v vim >/dev/null 2>&1; then
    ed=vim
fi
if command -v nvim >/dev/null 2>&1; then
    ed=nvim
fi
if [ -n "${editor}" ]; then
    ed=${editor}
fi
###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
###############################################################################
_need(){
    local cmd=${1}
    if ! command -v $cmd >/dev/null 2>&1;then
        echo "need $cmd"
        exit 1
    fi
}

install() {
    _need unzip

    cat ${this}/msg

    cat msg
    _installV2ray
    _installFetcher
    _installFastestPort
    _installService

    _config
}

_installV2ray() {
    echo "Install v2ray..."
    ${this}/scripts/installV2ray.sh ${this} || { echo "Install v2ray failed"; exit 1; }
    if [ ! -e ${this}/v2ray/v2ray ];then
        echo "${RED}Install v2ray failed!${NORMAL}"
        exit 1
    fi
}

_installFetcher() {
    echo "Install fetcher..."
    if [ -d fetcher ]; then
        echo "Already exist fetcher,skip"
        return
    fi
    curl https://gitee.com/sunliang711/fetcher/raw/master/install.sh | bash -s ${this}
}

_installFastestPort() {
    cd ${this}
    if [ -d fastest-port ]; then
        echo "Already exist fastest-port,skip"
        return
    fi
    echo "Install fastest-port..."
    curl -fsSL https://gitee.com/sunliang711/fastest-port/raw/master/install.sh | bash -s install ${this}
}

_config() {
    sed -e "s|output_file: .*|output_file: /tmp/v2backend.json|" ${this}/fetcher/fetcher.yaml >/tmp/fetcher.yaml
    mv /tmp/fetcher.yaml ${this}/fetcher/fetcher.yaml

    _runAsRoot "systemctl daemon-reload"
}

_installService() {
    local rootDir=${this}
    cd ${this}
    sed -e "s|<START_PRE>|${rootDir}/bin/v2relay.sh _start_frontend_pre|g" \
        -e "s|<START>|${rootDir}/v2ray/v2ray -c ${rootDir}/etc/v2frontend.json|g" \
        -e "s|<START_POST>|${rootDir}/bin/v2relay.sh _start_frontend_post|g" \
        -e "s|<STOP_POST>|${rootDir}/bin/v2relay.sh _stop_frontend_post|g" \
        -e "s|<USER>|${user}|g" \
        -e "s|<PWD>|${rootDir}/bin|g" \
        template/v2frontend.service >/tmp/v2frontend.service
    _runAsRoot "mv /tmp/v2frontend.service /etc/systemd/system"

    sed -e "s|<START_PRE>|${rootDir}/bin/v2relay.sh _start_backend_pre|g" \
        -e "s|<START>|${rootDir}/v2ray/v2ray -c ${rootDir}/etc/v2backend.json|g" \
        -e "s|<START_POST>|${rootDir}/bin/v2relay.sh _start_backend_post|g" \
        -e "s|<STOP_POST>|${rootDir}/bin/v2relay.sh _stop_backend_post|g" \
        -e "s|<USER>|${user}|g" \
        -e "s|<PWD>|${rootDir}/bin|g" \
        template/v2backend.service >/tmp/v2backend.service
    _runAsRoot "mv /tmp/v2backend.service /etc/systemd/system"
    echo "Edit fetcher.yaml file to update subscription URL"
    echo "Add ${this}/bin to PATH manaually"
}

uninstall() {
    _runAsRoot "systemctl stop v2frontend.service"
    _runAsRoot "systemctl stop v2backend.service"

    cd ${this}
    echo "Remove fetcher..."
    /bin/rm -rf fetcher
    echo "Remove v2ray..."
    /bin/rm -rf v2ray
    echo "Remove fastest-port..."
    /bin/rm -rf fastest-port

    echo "Remote v2frontend.service"
    _runAsRoot "/bin/rm -rf /etc/systemd/system/v2frontend.service"
    echo "Remote v2backend.service"
    _runAsRoot "/bin/rm -rf /etc/systemd/system/v2backend.service"

}

em() {
    $ed $0
}

###############################################################################
# write your code above
###############################################################################
function _help() {
    cat <<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    # perl -lne 'print "\t$1" if /^\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE})
    # perl -lne 'print "\t$2" if /^\s*(function)?\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | grep -v '^\t_'
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\w+)\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
"" | -h | --help | help)
    _help
    ;;
*)
    "$@"
    ;;
esac
