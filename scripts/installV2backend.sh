#!/bin/bash
if [ -z "${BASH_SOURCE}" ]; then
    this=${PWD}
    logfile="/tmp/$(%FT%T).log"
else
    rpath="$(readlink ${BASH_SOURCE})"
    if [ -z "$rpath"]; then
        rpath=${BASH_SOURCE}
    fi
    this="$(cd $(dirname $rpath) && pwd)"
    logfile="/tmp/$(basename ${BASH_SOURCE}).log"
fi

export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

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

_err(){
    echo "$*" >&2
}

_command_exists(){
    command -v "$@" > /dev/null 2>&1
}

rootID=0

_runAsRoot(){
    cmd="${*}"
    bash_c='bash -c'
    if [ "${EUID}" -ne "${rootID}" ];then
        if _command_exists sudo; then
            bash_c='sudo -E bash -c'
        elif _command_exists su; then
            bash_c='su -c'
        else
            cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
            exit 1
        fi
    fi
    # only output stderr
    (set -x; $bash_c "${cmd}" >> ${logfile} )
}

_run(){
    # only output stderr
    (set -x; bash -c "${cmd}" >> ${logfile})
}

function _insert_path(){
    if [ -z "$1" ];then
        return
    fi
    echo -e ${PATH//:/"\n"} | grep -c "^$1$" >/dev/null 2>&1 || export PATH=$1:$PATH
}

function _root(){
    if [ ${EUID
        } -ne ${rootID
        }
    ];then
        echo "Need run as root!"
        echo "Requires root privileges."
        exit 1
    fi
}

ed=vi
if _command_exists vim; then
    ed=vim
fi
if _command_exists nvim; then
    ed=nvim
fi
# use ENV: editor to override
if [ -n "${editor}" ];then
    ed=${editor
}
fi
###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
###############################################################################
# TODO
rootDir="$(cd ${this}/.. && pwd)"

_installFetcher() {
    cd ${rootDir}
    echo "Install fetcher..."
    if [ -d fetcher ]; then
        echo "${YELLOW}Already exist fetcher,skip${NORMAL}"
        return
    fi
    curl https://gitee.com/sunliang711/fetcher/raw/master/install.sh | bash -s ${rootDir}
    sed -e "s|output_file: .*|output_file: /tmp/v2backend.json|" ${rootDir}/fetcher/fetcher.yaml >/tmp/fetcher.yaml
    mv /tmp/fetcher.yaml ${rootDir}/fetcher/fetcher.yaml

    _runAsRoot "systemctl daemon-reload"
}

_installFastestPort() {
    cd ${rootDir}
    if [ -d fastest-port ]; then
        echo "${YELLOW}Already exist fastest-port,skip${NORMAL}"
        return
    fi
    echo "Install fastest-port..."
    curl -fsSL https://gitee.com/sunliang711/fastest-port/raw/master/install.sh | bash -s install ${rootDir}
}

install(){
    bash ${this}/installV2ray.sh "${rootDir}" || { echo "Install v2ray failed!"; exit 1; }

    cat ${this}/backend_msg
    # install service
    local start_pre="${rootDir}/bin/v2relay.sh _start_backend_pre"
    local start="${rootDir}/v2ray/v2ray -c ${rootDir}/etc/v2backend.json"
    local start_post="${rootDir}/bin/v2relay.sh _start_backend_post"
    local stop_post="${rootDir}/bin/v2relay.sh _stop_backend_post"
    local pwd="${rootDir}/bin"
    sed -e "s|<START_PRE>|${start_pre}|g" \
        -e "s|<START>|${start}|g" \
        -e "s|<START_POST>|${start_post}|g" \
        -e "s|<STOP_POST>|${stop_post}|g" \
        -e "s|<USER>|${user}|g" \
        -e "s|<PWD>|${pwd}|g" \
        ${rootDir}/template/v2backend.service >/tmp/v2backend.service
    _runAsRoot "mv /tmp/v2backend.service /etc/systemd/system"
    _runAsRoot "systemctl daemon-reload"

    echo "${green}Edit fetcher.yaml file to update subscription URL${NORMAL}"
    echo "Add ${rootDir}/bin to PATH manaually"
    _insert_path "${rootDir}/bin"

    _installFetcher
    _installFastestPort
}

em(){
    $ed $0
}

###############################################################################
# write your code above
###############################################################################
function _help(){
    cd "${this}"
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    # perl -lne 'print "\t$1" if /^\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE})
    # perl -lne 'print "\t$2" if /^\s*(function)?\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | grep -v '^\t_'
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
     ""|-h|--help|help)
        _help
        ;;
    *)
        "$@"
esac
