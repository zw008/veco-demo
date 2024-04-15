#!/bin/bash
# Copyright (c) 2023 VMware, Inc. All rights reserved.
#
# Deploys Edge Compute ESXi ova to a hypervisor, e.g. ESXi.

set -o errexit
set -o pipefail
set -o nounset

# ----------------------------------------------------------------------------
usage() {
  local usage
  usage="
USAGE:
  $(basename "$0") [-v esxi|fusion|ws ] -o ec.ova -m vm_name [-f ec_firstboot.yaml]

  Deploys Edge Compute ESXi .ova as a VM to a hypervisor, e.g. ESXi (directly or
  through vCenter Server).

  WARNING: This is a developer productivity helper tool. It is unsuitable for
  production purpose (due to trade-offs that weaken security).

  Common args:
    -v : Hypervisor type, 'esx' or 'fusion' or 'ws'.
    -o : Edge Compute ESXi .ova file path.
    -m : Edge Compute ESXi VM name to import ova as.
    -r : Edge Compute ESXi VM root password (optional).
    -f : Edge Compute firstboot yaml file path (optional).
    -s : KPS server URL.
    -h : Print usage of this tool.

  Hypervisor specific args:

  -v esx
     -l : vSphere (ESXi/VC) API endpoint URL (e.g. https://hostname_or_ip/sdk ).
     -k : Ignore certificate error for connecting to ESXi API endpoint (optional).
     -u : ESXi/VC account username.
     -p : ESXi/VC account password.
     -n : ESXi/VC network name (e.g 'VM Network' ).
     -d : ESXi/VC datastore name (e.g. 'datastore1' ).
     -z : VC datacenter name

  -v fusion|ws
     -t Virtual Machine library directory (under which to store imported .ova VM)

  "
  echo "$usage"
}

fatal() {
  >&2 echo -e "ERROR:" "$@"
  exit 1
}

HYPERVISOR=""
OVA=""
VMNAME=""
KFBYAML=""
GOVC_URL=""
GOVC_USERNAME=""
# Allow VC/ESXi password to be set via env var instead of CLI arg too.
GOVC_PASSWORD="${GOVC_PASSWORD:-}"
GOVC_DATASTORE=""
GOVC_NETWORK=""
GOVC_INSECURE=""
KROOTPWD=""
VMLIBDIR=""
KPSURL=""
GOVC_DATACENTER=""

while getopts "v:o:m:f:c:l:u:p:d:n:r:s:t:z:kh" opt; do
  case "$opt" in
    "v")
      HYPERVISOR="$OPTARG";;
    "o")
      OVA="$OPTARG";;
    "m")
      VMNAME="$OPTARG";;
    "f")
      KFBYAML="$OPTARG";;
    "l")
      export GOVC_URL="$OPTARG";;
    "u")
      export GOVC_USERNAME="$OPTARG";;
    "p")
      export GOVC_PASSWORD="$OPTARG";;
    "d")
      export GOVC_DATASTORE="$OPTARG";;
    "n")
      export GOVC_NETWORK="$OPTARG";;
    "k")
      export GOVC_INSECURE=1;;
    "z")
      export GOVC_DATACENTER="$OPTARG";;
    "r")
      KROOTPWD="$OPTARG";;
    "t")
      VMLIBDIR="$OPTARG";;
    "s")
      KPSURL="$OPTARG";;
    "h")
      usage ; exit 0 ;;
    *)
      usage ; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# ----------------------------------------------------------------------------
# Tooling dependencies

BASE64=${BASE64:-$(command -v base64 || :)}
CHMOD=${CHMOD:-$(command -v chmod || :)}
FIND=${FIND:-$(command -v find || :)}
GOVC=${GOVC:-$(command -v govc || :)}
GREP=${GREP:-$(command -v grep || :)}
MKDIR=${MKDIR:-$(command -v mkdir || :)}
STAT=${STAT:-$(command -v stat || :)}
SUDO=${SUDO:-$(command -v sudo || :)}
UNAME=${UNAME:-$(command -v uname || :)}

FUSIONPATH=${FUSIONPATH:-/Applications/VMware Fusion.app}
WSPATH=${WSPATH:-/usr/local/vmware-workstation}

# Checks
OS=$(uname)
OS_PLATFORM=$(uname -m)
case "$OS" in
  "Linux")
    BASE64_ARGS="-w 0";;
  "Darwin")
    BASE64_ARGS="-b 0";
    # Unfortunately currently now Rosetta 2 support for virt s/w on macOS Apple Silicon.
    if [ "$OS_PLATFORM" != "x86_64" ]; then
      fatal "unsupported machine hardware platform $(uname -m), only Intel (x86_64) is supported";
    fi;;
    *)
    fatal "unsupported OS: $OS";;
esac

test "$#" == "0" || { fatal "extra unrecognized args\n$(usage)"; }
test -n "$HYPERVISOR" || { fatal "missing -v arg\n$(usage)"; }
test -n "$OVA" || { fatal "missing -o arg\n$(usage)"; }
test -n "$VMNAME" || { fatal "missing -m arg\n$(usage)"; }
if [ "$HYPERVISOR" == "esx" ] ; then
  test -n "$GOVC_URL" || { fatal "missing -l arg\n$(usage)"; }
  test -n "$GOVC_USERNAME" || { fatal "missing -u arg\n$(usage)"; }
  test -n "$GOVC_PASSWORD" || { fatal "missing -p arg\n$(usage)"; }
  test -n "$GOVC_DATASTORE" || { fatal "missing -d arg\n$(usage)"; }
  test -n "$GOVC_NETWORK" || { fatal "missing -n arg\n$(usage)"; }
  test -n "$GOVC_DATACENTER" || { fatal "missing -z arg\n$(usage)"; }
  test -x "$GOVC" || { fatal "missing govc command"; }
fi
if [ "$HYPERVISOR" == "fusion" ]; then
  test -d "$FUSIONPATH" || {
    fatal "missing VMware Fusion.app, if installed at location other than \
'$FUSIONPATH', please export env var FUSIONPATH pointing to correct path";
  }
  VMRUN="$FUSIONPATH/Contents/Public/vmrun"
  test -x "$VMRUN" || { fatal "missing '$VMRUN' command"; }
  OVFTOOL="$FUSIONPATH/Contents/Library/VMware OVF Tool/ovftool"
  test -x "$OVFTOOL" || { fatal "missing '$OVFTOOL' command"; }
  test -x "$MKDIR" || { fatal "missing mkdir command"; }
  test -n "$VMLIBDIR" || { fatal "missing -t arg\n$(usage)"; }
fi
if [ "$HYPERVISOR" == "ws" ]; then
  test -d "$WSPATH" || {
    fatal "missing VMware Workstation, if if installed at location other \
'$WSPATH', please export env var WSPATH pointing to correct path";
  }
  VMRUN="$WSPATH/bin/vmrun"
  test -x "$VMRUN" || { fatal "missing '$VMRUN' command"; }
  OVFTOOL="$WSPATH/bin/ovftool"
  test -x "$OVFTOOL" || { fatal "missing '$OVFTOOL' command"; }
  test -x "$MKDIR" || { fatal "missing mkdir command"; }
  test -n "$VMLIBDIR" || { fatal "missing -t arg\n$(usage)"; }
fi
if [[ -n "$KFBYAML" ]] ; then
  test -x "$BASE64" || { fatal "missing base64 command"; }
  test -f "$KFBYAML" || { fatal "missing file $KFBYAML"; }
  # shellcheck disable=SC2086
  KFBYAML=$("$BASE64" $BASE64_ARGS < "$KFBYAML")
fi
if [[ -n "$KROOTPWD" ]]; then
  test -x "$BASE64" || { fatal "missing base64 command"; }
  # shellcheck disable=SC2086
  KROOTPWD=$(printf "%s" "$KROOTPWD" | "$BASE64" $BASE64_ARGS)
fi

# ----------------------------------------------------------------------------
# Deployment targets

deploy2esx() {
  # TODO: The OVF properties (PropertyMapping section below) is not being
  # passed to the actual VM currently, perhaps the .ovf template is missing
  # some config or ESXi host does not support OVF env properties? Need to
  # investigate. In the mean time, explicitly set `guestinfo.XYZ` VM
  # properties through additional `govc vm.change` call.
  local options=""
  read -r -d '' options <<EOT || :
{
  "DiskProvisioning": "thin",
  "IPAllocationPolicy": "dhcpPolicy",
  "IPProtocol": "IPv4",
  "PropertyMapping": [
    {
      "key": "guestinfo.ec.firstboot",
      "value": "$KFBYAML"
    },
    {
      "key": "guestinfo.root.passwd",
      "value": "$KROOTPWD"
    },
    {
      "key": "guestinfo.ec.url",
      "value": "$KPSURL"
    },
    {
      "key": "guestinfo.shell.enabled",
      "value": "True"
    },
    {
      "key": "guestinfo.ssh.enabled",
      "value": "True"
    }
  ],
  "NetworkMapping": [
    {
      "Name": "VM Network",
      "Network": "$GOVC_NETWORK"
    }
  ],
  "MarkAsTemplate": false,
  "PowerOn": false,
  "InjectOvfEnv": false,
  "WaitForIP": false,
  "Name": "$VMNAME"
}
EOT

  # Import the ova as a VM.
  # Below commands take input from $GOVC_XYZ vars, e.g. $GOVC_URL etc.
  $GOVC import.ova -options - "$OVA" <<<"$options"

  # Add .vmx entries for guestenv keys.
  $GOVC vm.change \
    -e "guestinfo.ec.firstboot=$KFBYAML" \
    -e "guestinfo.root.passwd=$KROOTPWD" \
    -e "guestinfo.ec.url=$KPSURL" \
    -e "guestinfo.shell.enabled=True" \
    -e "guestinfo.ssh.enabled=True" \
    -vm "$VMNAME"

  # Power-on the VM.
  $GOVC vm.power -on "$VMNAME"

  echo "SUCCESS: Imported and powered on '$VMNAME' VM on $GOVC_URL"
}

# For a nested VM to get DHCP access, vmnet devices need to be
# put into promiscuous mode. See https://kb.vmware.com/s/article/287
enable_wslinux_net_promiscous_mode() {
  if [ "$($UNAME -s)" == "Linux" ]; then
    $STAT --format="%a" /dev/vmnet* | $GREP -qc '..[67]' || {
        $SUDO $CHMOD a+rw /dev/vmnet*
    }
  fi
}

deploy2local() {
  local hypervisor="$1"

  # Import .ova as a VM.
  $MKDIR -p "$VMLIBDIR"
  local VMDIR="$VMLIBDIR/$VMNAME"
  "$OVFTOOL" "$OVA" "$VMDIR"

  # Add .vmx entries for guestenv keys.
  local VMX=$($FIND "$VMDIR" -type f -name "*.vmx")
  test -n "$KFBYAML" && echo "guestinfo.ec.firstboot=$KFBYAML" >> "$VMX"
  test -n "$KROOTPWD" && echo "guestinfo.root.passwd=$KROOTPWD" >> "$VMX"
  test -n "$KPSURL" && echo "guestinfo.ec.url=$KPSURL" >> "$VMX"
  echo "guestinfo.shell.enabled=True" >> "$VMX"
  echo "guestinfo.ssh.enabled=True" >> "$VMX"

  # Power-on the VM.
  enable_wslinux_net_promiscous_mode
  "$VMRUN" -T "$hypervisor" start "$VMX" nogui
  "$VMRUN" -T "$hypervisor" list

  # Wait for the machine to get IP.
  echo "Waiting for VM to acquire IP..."
  "$VMRUN" -T "$hypervisor" getGuestIPAddress "$VMX" -wait

  echo "SUCCESS: Imported and powered on '$VMX'"
}

# ----------------------------------------------------------------------------

main() {
  case "$HYPERVISOR" in
    "esx")
      deploy2esx;;
    "fusion"|"ws")
      deploy2local "$HYPERVISOR";;
    *)
      fatal "Unknown hypervisor $HYPERVISOR";;
  esac
}

main
