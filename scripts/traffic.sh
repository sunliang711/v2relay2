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
    local rootID=0
    if [ "${EUID}" -ne "${rootID}" ]; then
        echo -n "Not root, try to run as root.."
        # or sudo sh -c ${cmd} ?
        # if eval "sudo ${cmd}"; then
        if sudo sh -c "${cmd}"; then
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

rootID=0
function _root() {
    if [ ${EUID} -ne ${rootID} ]; then
        echo "Need run as root!"
        echo "Requires root privileges."
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
v2relay_root=${this}/..
fetcher_root=${v2relay_root}/fetcher
v2ray_root=${v2relay_root}/v2ray
fastestPort_root=${v2relay_root}/fastestPort
template_root=${v2relay_root}/template
etc_root=${v2relay_root}/etc

dest=${v2relay_root}/net-traffic

logfile=/tmp/v2relay.log
_redir_log(){
    exec 3>&1
    exec 4>&2
    exec 1>>${logfile}
    exec 2>>${logfile}
}

_restore(){
    exec 1>&3 3>&-
    exec 2>&4 4>&-
}

_tags() {
    tags="$(perl -lne 'print $1 if /\"tag\"\s*:\s*\"(.+)\"/' ${etc_root}/v2frontend.json)"
    echo "$tags"
}

# 增加port到iptables里监听流量
function _addWatchPorts() {
    _redir_log
    echo "_addWatchPorts..."
    local tags="$(_tags)"
    for tag in ${tags}; do
        # echo "t: ${tag}"
        local typ=$(echo ${tag} | awk -F: '{print $1}')
        local port=$(echo ${tag} | awk -F: '{print $2}')
        local remark=$(echo ${tag} | awk -F: '{print $3}')
        # echo "type: ${typ}"
        # echo "port: ${port}"
        # echo "remark: ${remark}"
        if [ -z "${port}" ];then
            continue
        fi
        cmd=$(cat <<EOF
            if ! iptables -L OUTPUT -n --line-numbers 2>/dev/null | grep -qP "spt:$port\b";then
                echo "Add port: $port to OUTPUT"
                iptables -A OUTPUT -p tcp --sport $port 2>/dev/null
            fi
            if ! iptables -L INPUT -n --line-numbers 2>/dev/null | grep -qP "dpt:$port\b";then
                echo "Add port: $port to INPUT"
                iptables -A INPUT -p tcp --dport $port 2>/dev/null
            fi
EOF
        )
        _runAsRoot "${cmd}"
    done
}

# 删除iptables里的流量监听
function _delWatchPorts() {
    _redir_log
    echo "_delWatchPorts..."
    local tags="$(_tags)"
    for tag in ${tags}; do
        # echo "t: ${tag}"
        local typ=$(echo ${tag} | awk -F: '{print $1}')
        local port=$(echo ${tag} | awk -F: '{print $2}')
        local remark=$(echo ${tag} | awk -F: '{print $3}')
        # echo "type: ${typ}"
        # echo "port: ${port}"
        # echo "remark: ${remark}"
        cmd=$(
            cat <<EOF
            echo "Clear port: $port"
            iptables -D OUTPUT -p tcp --sport $port 2>/dev/null
            iptables -D INPUT -p tcp --dport $port 2>/dev/null
EOF
        )

        _runAsRoot "${cmd}"
    done
}

firewallCMD=iptables
# Core function!!
_snapshot(){
    #-x -L INPUT|OUTPUT 输出的流量以字节为单位: $1要么为-x要么为空
    declare -a chains=(OUTPUT INPUT)
    inByte=${1}

    local tags="$(_tags)"
    for chain in "${chains[@]}";do
        sudo "${firewallCMD}" -L $chain -nv 2>/dev/null | head -1
        printf "%-10s%-10s%-22s%-18s%-18s\n" "protocol" "port" "remark" "bytes" "packets"
        local output="$(sudo "${firewallCMD}" -L ${chain} -nv ${inByte} 2>/dev/null)"
        for tag in ${tags}; do
            # echo "t: ${tag}"
            local typ=$(echo ${tag} | awk -F: '{print $1}')
            local port=$(echo ${tag} | awk -F: '{print $2}')
            local remark=$(echo ${tag} | awk -F: '{print $3}')
            oldIFS="${IFS}"
            IFS='|'
            # protocol port bytes pkts
            read pro pt bs pks <<< $(echo "$output"| grep -E "(dpt|spt):${port}\b" | awk '{printf "%s|%s|%s|%s",$3,$10,$2,$1}')
            # bs=$(printf "%'d" $bs)
            # pks=$(printf "%'d" $pks)
            # add comma: 1234567 -> 1,234,567
            bs=$(echo $bs | perl -ple "s|(?<=\d)(?=(\d\d\d)+\D*$)|,|g" )
            pks=$(echo $pks | perl -ple "s|(?<=\d)(?=(\d\d\d)+\D*$)|,|g" )
            printf "%-10s%-10s%-22s%-18s%-18s\n" "$pro" "$pt" "$typ->$remark" "$bs" "$pks"
            IFS="${oldIFS}"
        done
        echo "---------------------------------------------------------------------"
    done
}

function _monitor(){
    echo "Press <C-c> to quit."
    date +%FT%T
    echo
    _snapshot $1
}

monitor(){
    echo "add -x to show traffic in byte"
    watch -d -n 1 $0 _monitor $1
}

saveDay(){
    local filename=year-$(date +%Y)
    if [ ! -d $dest ];then
        mkdir $dest
    fi
    echo "saveDay..."
    (date +%FT%T;_snapshot) >> $dest/$filename
    _zero
}

saveHour(){
    local filename=month-$(date +%Y%m)
    if [ ! -d $dest ];then
        mkdir $dest
    fi
    echo "saveHour to $dest/$filename"
    (date +%FT%T;_snapshot) >> $dest/$filename
}

day(){
    local filename=year-$(date +%Y)
    $ed $dest/$filename
}

#zero counter in iptables
_zero(){
    _redir_log
    local tags="$(_tags)"
    for tag in ${tags}; do
        # echo "t: ${tag}"
        # local typ=$(echo ${tag} | awk -F: '{print $1}')
        local port=$(echo ${tag} | awk -F: '{print $2}')
        # local remark=$(echo ${tag} | awk -F: '{print $3}')
        echo "zero port: $port..."
        sudo ${firewallCMD} -L INPUT -n --line-numbers 2>/dev/null | grep -P "dpt:$port\b" | awk '{print $1}' | xargs -L 1 sudo ${firewallCMD} -L -Z INPUT 2>/dev/null
        sudo ${firewallCMD} -L OUTPUT -n --line-numbers 2>/dev/null| grep -P "spt:$port\b" | awk '{print $1}' | xargs -L 1 sudo ${firewallCMD} -L -Z OUTPUT 2>/dev/null
    done
}

hour(){
    local filename=month-$(date +%Y%m)
    $ed $dest/$filename
}

em() {
    $ed $0
}

###############################################################################
# write your code above
###############################################################################
function _help() {
    cd "${this}"
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
