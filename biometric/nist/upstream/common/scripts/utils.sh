#!/bin/bash
# Kenshiki Labs modification, 2026-10-16: robust Bash tests, diagnostics and substitutions.
# Original source: NIST; provenance and original digests are in upstream-manifest.json.

SUCCESS_MESSAGE='[SUCCESS]'
success=0
failure=1

bold=$(tput bold)
normal=$(tput sgr0)

reqOS="Ubuntu 24.04.3 LTS"

# Function to check version of OS
check_os() {
    currentOS=$(lsb_release -a 2> /dev/null | grep "Description" | awk -F":" '{ print $2 }' | sed -e 's/^[[:space:]]*//')
    if [[ "$reqOS" != "$currentOS" ]]; then
        echo "${bold}[ERROR] You are not running the correct version of the operating system, which should be $reqOS.  Please install the correct operating system and re-run this validation package.${normal}" >&2
        exit $failure
    fi
    return $?
}

# Function to check and install the necessary 
# packages to run validation
check_packages() {
    echo -n "Checking installation of required packages "
    for package in g++ cmake sed bc gawk grep
    do
        if [[ $(dpkg-query -W -f='${Status}' $package 2>/dev/null | grep -c "ok installed") -eq 0 ]];
    then
            sudo apt-get install -y $package;
        fi
    done
    echo "[SUCCESS]"
    return $?
}

# Function to check for the existence of
# required folders
check_folders() {
    if [[ ! -d "./config" ]]; then
        echo "[ERROR] ./config was not found.  Please fix this and re-run." >&2
        exit $failure
    fi

    if [[ ! -d "./lib" ]]; then
        echo "[ERROR] ./lib was not found.  Please fix this and re-run." >&2
        exit $failure
    else
        if [[ ! "$(ls -A ./lib)" ]]; then
            echo "[ERROR] The ./lib directory is empty.  Please place your software library files in ./lib and re-run." >&2
            exit $failure
        fi
    fi

    if [[ ! -s "./doc/version.txt" ]]; then
        echo "[ERROR] ./doc/version.txt was not found.  Per the API document, ./doc/version.txt must document versioning information for the submitted software." >&2
        echo "Please fix this and re-run."
        exit $failure
    fi
    return $?
}

# Function to log OS info to text file
log_os() {
    echo "$reqOS" > validation/os.txt    
    return $?
}

# Function to get current frvt_structs.h version
get_frvt_header_version() {
    major=$(grep "FRVT_STRUCTS_MAJOR_VERSION{" ../common/src/include/frvt_structs.h | awk -F'{' '{ print $2 }' | awk -F'}' '{ print $1 }')
    minor=$(grep "FRVT_STRUCTS_MINOR_VERSION{" ../common/src/include/frvt_structs.h | awk -F'{' '{ print $2 }' | awk -F'}' '{ print $1 }')
    echo "${major}.${minor}"
    return $?
}

# Function to merge output files together
# merge "filename"
function merge() {
    name=$1; shift; suffixes="$*"
    for suffix in $suffixes
    do
        tmp=$(dirname "$name")
        tmp=$tmp/tmp.txt
        firstfile=$(ls "${name}.${suffix}."* | head -n1)
        # Get header
        head -n1 $firstfile > $tmp
        sed -i "1d" ${name}.${suffix}.*
        cat ${name}.${suffix}.* >> $tmp
        mv $tmp ${name}.${suffix}
        rm -rf ${name}.${suffix}.*
    done
    return $?
}
