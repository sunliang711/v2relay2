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
        # echo -n "Not root, try to run as root.."
        # or sudo sh -c ${cmd} ?
        # if eval "sudo ${cmd}";then
        if sudo sh -c "${cmd}"; then
            # echo "ok"
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
fastestPort_root=${v2relay_root}/fastest-port
template_root=${v2relay_root}/template
etc_root=${v2relay_root}/etc
scripts_root=${v2relay_root}/scripts

redir_chain=redir_chain
firewallCMD=iptables
beginCron="#begin v2relay cron"
endCron="#end v2relay cron"

logfile=/tmp/v2relay.log
_redir_log(){
    exec 3>&1
    exec 4>&2
    exec 1>>${logfile}
    exec 2>>${logfile}
}

_restore_log(){
    exec 1>&3 3>&-
    exec 2>&4 4>&-
}

_start_frontend_pre() {
    echo "start frontend pre..."
    ${scripts_root}/traffic.sh _addWatchPorts
}

_start_frontend_post() {
    echo "start frontend post"
    _addCron
}

_stop_frontend_post() {
    echo "stop frontend post..."
    ${scripts_root}/traffic.sh _delWatchPorts
    _delCron
}

_start_backend_pre() {
    echo "start v2backend pre..."
    if [ ! -e ${this}/../etc/v2backend.json ]; then
        echo "No etc/v2backend.json file."
        exit 1
    fi
    grep 'BEGIN outbound address:' ${this}/../etc/v2backend.json | awk -F: '{print $2}' | sort | uniq >/tmp/outboundAddress
}

_start_backend_post() {
    echo "start v2backend post..."
    best
}

_stop_backend_post() {
    _clearRule
}

start() {
    echo "Start v2frontend..."
    _runAsRoot "systemctl start v2frontend&"
    echo "Start v2backend..."
    _runAsRoot "systemctl start v2backend&"

    _runAsRoot "journalctl -u v2backend -f"
}

stop() {
    echo "Stop v2frontend..."
    _runAsRoot "systemctl stop v2frontend"
    echo "Stop v2backend..."
    _runAsRoot "systemctl stop v2backend"
}

restart() {
    stop
    start
}

status() {
    echo
}

best() {
    echo "best..."
    # 读取fastest-port的配置文件，获取它需要的输入文件路径
    local fastestInputFile="$(perl -lne 'print $1 if /portFile=\"(.+)\"/' ${fastestPort_root}/config.toml)"
    if [ -z "${fastestInputFile}" ]; then
        echo "Cannot find fastest-port input file.Check it's config file!!"
        exit 1
    fi

    # 读取fastest-port的配置文件，获取它需要的输出文件路径
    local fastestOutputFile="$(perl -lne 'print $1 if/resultFile=\"(.+)\"/' ${fastestPort_root}/config.toml)"
    if [ -z "${fastestOutputFile}" ]; then
        echo "Cannot find fastest-port output file.Check it's config file!!"
        exit 1
    fi

    # 构造fastest-port的输入文件
    perl -lne 'print $1 if/"BEGIN port":"([^"]+)"/' ${v2relay_root}/etc/v2backend.json >"${fastestInputFile}"
    echo "fastest-port input file: ${fastestInputFile}"
    cat ${fastestInputFile}
    echo "fastest-port output file: ${fastestOutputFile}"

    (cd ${fastestPort_root} && ./fastest-port -c config.toml)

    echo "[fastest-port result]:"
    cat ${fastestOutputFile}

    local separator='`'
    local bestLine=$(sort -n -t ${separator} -k 2 ${fastestOutputFile} | head -1)
    echo "best node: ${bestLine}"
    local bestPort=$(echo ${bestLine} | awk -F${separator} '{print $1}')
    if [ -z ${bestPort} ]; then
        echo "Find best error"
        echo "Suggest: run fetchSub?"
        exit 1
    fi
    echo "best port: ${bestPort}"

    local virtualPort=$(perl -lne "print if /BEGIN virtual port/../END virtual port/" ${etc_root}/v2frontend.json | grep "\"port\"" | grep -o '[0-9][0-9]*')
    echo "virtualPort: ${virtualPort}"

    _clearRule
    _addRule ${virtualPort} ${bestPort}
}

check() {
    echo -n "$(date +%FT%T) check..."
    local virtualPort=$(perl -lne "print if /BEGIN virtual port/../END virtual port/" ${etc_root}/v2frontend.json | grep "\"port\"" | grep -o '[0-9][0-9]*')
    if curl -s -x socks5://localhost:${virtualPort} --retry 2 ifconfig.me >/dev/null 2>&1; then
        echo "OK"
    else
        echo "best..."
        best
    fi
}

_addRule() {
    local srcPort=${1:?'missing src port'}
    local destPort=${2:?'missing dest port'}
    echo "Add rule: redirect ${srcPort} to ${destPort}"
    # new
    echo "  1.> New chain: ${redir_chain}"
    _runAsRoot "${firewallCMD} -t nat -N ${redir_chain}"

    # echo "after new chain"
    # _runAsRoot "${firewallCMD} -t nat -n --line-numbers -L"

    echo "  2.> Add redir rule to chain: ${redir_chain} ($srcPort -> $destPort)"
    _runAsRoot "${firewallCMD} -t nat -A ${redir_chain} -p tcp --dport ${srcPort} -j REDIRECT --to-ports ${destPort}"
    # echo "after add rule to chain"
    # _runAsRoot "${firewallCMD} -t nat -n --line-numbers -L"

    # reference
    echo "  3.> Reference chain: ${redir_chain}"
    _runAsRoot "${firewallCMD} -t nat -A OUTPUT -p tcp --dport ${srcPort} -j ${redir_chain}"
    _runAsRoot "${firewallCMD} -t nat -A PREROUTING -p tcp --dport ${srcPort} -j ${redir_chain}"

    # echo "after reference"
    # _runAsRoot "${firewallCMD} -t nat -n --line-numbers -L"
}

_clearRule() {
    echo "Clear rule..."
    # delete reference
    echo "  1.> Delete reference"
    #如果有多条的话，要从index大的开始删除，否则会报index越界错误,所以要sort -r倒序；因为删除小的后，大的index会变小
    _runAsRoot "${firewallCMD} -t nat -n --line-numbers -L OUTPUT | grep ${redir_chain} | grep -o '^[0-9][0-9]*' | sort -r | xargs -n 1 ${firewallCMD} -t nat -D OUTPUT"
    _runAsRoot "${firewallCMD} -t nat -n --line-numbers -L PREROUTING | grep ${redir_chain} | grep -o '^[0-9][0-9]*' | sort -r | xargs -n 1 ${firewallCMD} -t nat -D PREROUTING"

    #flush
    echo "  2.> Flush chain: ${redir_chain}"
    _runAsRoot "${firewallCMD} -t nat -F ${redir_chain}"

    #delete
    echo "  3.> Delete chain: ${redir_chain}"
    _runAsRoot "${firewallCMD} -t nat -X ${redir_chain}"
}

_addCron() {
    local tmpCron=/tmp/cron.tmp$(date +%FT%T)
    if crontab -l 2>/dev/null | grep -q "${beginCron}"; then
        echo "Already exist,quit."
        return 0
    fi
    cat >${tmpCron} <<-EOF
	${beginCron}
	# NOTE!! saveHour saveDay need run iptables with sudo,
	# so make sure you can run iptables with sudo no passwd
	# or you are root
	0 * * * * ${this}/v2relay.sh traffic saveHour
	59 23 * * * ${this}/v2relay.sh traffic saveDay
	#
    # 高峰时段
	# Peek Hour: 9-23,0-2 
	5 9-23,0-2 * * * ${this}/v2relay.sh best >>/tmp/best.log 2>&1
	*/3 9-23,0-2 * * * ${this}/v2relay.sh check >>/tmp/best.log 2>&1

	# Not Peek Hour: 3-8
	5 3-8 * * * ${this}/v2relay.sh best >>/tmp/best.log 2>&1
	0,30 3-8 * * * ${this}/v2relay.sh check >>/tmp/best.log 2>&1

	${endCron}
	EOF

    (
        crontab -l 2>/dev/null
        cat ${tmpCron}
    ) | crontab -
}

_delCron() {
    (crontab -l 2>/dev/null | sed -e "/${beginCron}/,/${endCron}/d") | crontab -
}

log() {
    echo
}

fetchSub() {
    cd ${fetcher_root}
    ./fetcher fetch

    cd ${this}
    local oldBackends="../etc/old-backends"
    if [ ! -d "${oldBackends}" ]; then
        mkdir -p "${oldBackends}"
    fi

    if [ -e ../etc/v2backend.json ]; then
        mv ../etc/v2backend.json "${oldBackends}/v2backend-$(date +%FT%T).json"
    fi

    mv /tmp/v2backend.json ../etc
}

fetchConfig() {
    $ed ${fetcher_root}/fetcher.yaml
}

traffic(){
    ${scripts_root}/traffic.sh "$@"
}

em() {
    $ed $0
}

###############################################################################
# write your code above
###############################################################################
function _help() {
    cd ${this}
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
