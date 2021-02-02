#!/bin/bash

rpath="$(readlink ${BASH_SOURCE})"
if [ -z "$rpath" ];then
    rpath=${BASH_SOURCE}
fi

root="$(cd $(dirname $rpath) && pwd)"
cd "$root"

need(){
    if ! command -v $1 >/dev/null 2>&1;then
        echo "need $1"
        exit 1
    fi
}

install(){
    dest=${1:?'missing install location'}
    if [ ! -d ${dest} ];then
        echo "Create ${dest}"
        mkdir -p ${dest}
    fi
    dest="$(cd ${dest} && pwd)"
    echo "install location: $dest"
    version=${2:-4.32.1}

    need curl
    need unzip

    downloadDir=/tmp/v2ray-download
    echo "downloadDir: $downloadDir"
    if [ ! -d "$downloadDir" ];then
        mkdir "$downloadDir"
    fi
    cd "$downloadDir"

    case $(uname) in
        Darwin)
            url="https://source711.oss-cn-shanghai.aliyuncs.com/v2ray/${version}/MacOS/v2ray-macos.zip"
            # url="https://source711.oss-cn-shanghai.aliyuncs.com/v2ray/${version}/v2ray-macos-64.zip"
            zipfile=${url##*/}
            ;;
        Linux)
            url="https://source711.oss-cn-shanghai.aliyuncs.com/v2ray/${version}/Linux/v2ray-linux-64.zip"
            # url="https://source711.oss-cn-shanghai.aliyuncs.com/v2ray/${version}/v2ray-linux-64.zip"
            zipfile=${url##*/}
            ;;
    esac

    # rasperberry arm64
    if [ $(uname -m) == "aarch64" ];then
        # url="https://source711.oss-cn-shanghai.aliyuncs.com/v2ray/${version}/Linux/v2ray-linux-arm64-v8a.zip"
        url="https://source711.oss-cn-shanghai.aliyuncs.com/v2ray/${version}/v2ray-linux-arm64-v8a.zip"
        zipfile=${url##*/}
    fi

    if [ ! -e "$zipfile" ];then
        curl -LO "$url" || { echo "download $zipfile error"; exit 1; }
    else
        echo "Use ${downloadDir}/$zipfile cache file"
    fi

    echo "unzip zipfile: $zipfile..."
    unzip -d "$dest/v2ray" "$zipfile" || { echo "Extract v2ray zip file error"; exit 1; }

}

install $1
