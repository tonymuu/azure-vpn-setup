#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCENARIO=${2-}
if [[ $OSTYPE == msys* || $OSTYPE == cygwin* ]]; then
    export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/subscriptions"
    jq() { command jq --binary "$@"; }
    export -f jq
fi

arg() {
    local name=$1
    shift
    while (( $# )); do
        if [[ $1 == "$name" ]]; then printf '%s\n' "${2-}"; return; fi
        shift
    done
}

resource_id() { printf '/subscriptions/sub/resourceGroups/rg/providers/%s/%s\n' "$1" "$2"; }

add_resource() {
    local type=$1 name=$2 tag=${3-$RUN_ID}
    jq --arg type "$type" --arg name "$name" --arg id "$(resource_id "$type" "$name")" --arg tag "$tag" \
        '. + [{id:$id,name:$name,type:$type,tags:{vpnProvisionRun:$tag},properties:{subnets:[{name:"vpn01-subnet"}]}}]' \
        "$WORK_DIR/resources.json" >"$WORK_DIR/updated.json"
    mv "$WORK_DIR/updated.json" "$WORK_DIR/resources.json"
}

vm_model() {
    local key=$SSH_KEY
    case "$SCENARIO" in bad-key|foreign-resource|foreign-subnet|changed-delete-options) key=wrong-key ;; esac
    jq -n --arg id "$(resource_id Microsoft.Compute/virtualMachines "$VM")" --arg run "$RUN_ID" \
        --arg key "$key" --arg image "$IMAGE" --arg size "$SIZE" --arg user "$ADMIN" \
        --arg disk "$(resource_id Microsoft.Compute/disks "$DISK")" \
        --arg nic "$(resource_id Microsoft.Network/networkInterfaces "$NIC")" --argjson gb "$DISK_GB" '
        ($image|split(":")) as $parts |
        {id:$id,tags:{vpnProvisionRun:$run},hardwareProfile:{vmSize:$size},priority:"Regular",
        provisioningState:"Succeeded",osProfile:{adminUsername:$user,
        linuxConfiguration:{disablePasswordAuthentication:true,ssh:{publicKeys:[{keyData:$key}]}}},
        storageProfile:{imageReference:{publisher:$parts[0],offer:$parts[1],sku:$parts[2],version:$parts[3]},
        dataDisks:[],osDisk:{diskSizeGb:$gb,deleteOption:"Detach",managedDisk:{id:$disk,storageAccountType:"StandardSSD_LRS"}}},
        networkProfile:{networkInterfaces:[{id:$nic,deleteOption:"Detach"}]}}' |
        if [[ $SCENARIO == changed-delete-options ]]; then
            jq '.networkProfile.networkInterfaces[0].deleteOption="Delete"'
        else cat; fi
}

az() {
    printf '%s ' "$@" >>"$WORK_DIR/calls"
    printf '\n' >>"$WORK_DIR/calls"
    local action="${1-} ${2-} ${3-}" name type id arch
    case "$action" in
        'account list --all')
            printf '[{"id":"sub","name":"Test subscription","state":"Enabled","tenantId":"tenant"}]\n' ;;
        'account list-locations '*)
            printf '[{"name":"westus2"}]\n' ;;
        'group exists '*)
            if [[ $SCENARIO == collision || -f $WORK_DIR/group-created ]]; then printf 'true\n'; else printf 'false\n'; fi ;;
        'vm image list-skus')
            printf '[{"name":"12-gen2"},{"name":"12-arm64"}]\n' ;;
        'vm image show')
            arch=x64
            [[ $(arg --urn "$@") != *arm64* ]] || arch=Arm64
            [[ $SCENARIO != no-image ]] || arch=Unsupported
            jq -n --arg arch "$arch" '{name:"12.20261001.1",architecture:$arch,hyperVGeneration:"V2",
                osDiskImage:{operatingSystem:"Linux",sizeInGb:30},features:[]}' ;;
        'vm list-skus '*)
            cat <<'JSON'
[
 {"name":"Standard_B1s","resourceType":"virtualMachines","family":"standardBSFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"1"},{"name":"MemoryGB","value":"1"},{"name":"CpuArchitecture","value":"x64"},{"name":"HyperVGenerations","value":"V1,V2"}]},
 {"name":"Standard_B2pts_v2","resourceType":"virtualMachines","family":"standardBPSv2Family","restrictions":[],"capabilities":[{"name":"vCPUs","value":"2"},{"name":"MemoryGB","value":"1"},{"name":"CpuArchitecture","value":"Arm64"},{"name":"HyperVGenerations","value":"V2"}]},
 {"name":"Standard_Restricted","resourceType":"virtualMachines","family":"standardBSFamily","restrictions":[{"reasonCode":"NotAvailableForSubscription"}],"capabilities":[{"name":"vCPUs","value":"1"},{"name":"MemoryGB","value":"1"},{"name":"CpuArchitecture","value":"x64"},{"name":"HyperVGenerations","value":"V2"}]},
 {"name":"Standard_Mismatch","resourceType":"virtualMachines","family":"standardBSFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"1"},{"name":"MemoryGB","value":"1"},{"name":"CpuArchitecture","value":"x64"},{"name":"HyperVGenerations","value":"V1"}]},
 {"name":"Standard_NoQuota","resourceType":"virtualMachines","family":"noQuota","restrictions":[],"capabilities":[{"name":"vCPUs","value":"1"},{"name":"MemoryGB","value":"1"},{"name":"CpuArchitecture","value":"x64"},{"name":"HyperVGenerations","value":"V2"}]}
]
JSON
            ;;
        'vm list-usage '*)
            printf '[{"name":{"value":"cores"},"currentValue":0,"limit":10},{"name":{"value":"noQuota"},"currentValue":0,"limit":0}]\n' ;;
        'group create '*)
            touch "$WORK_DIR/group-created"
            jq -n --arg run "$RUN_ID" '{tags:{vpnProvisionRun:$run}}' ;;
        'group show '*)
            jq -n --arg run "$RUN_ID" '{tags:{vpnProvisionRun:$run}}' ;;
        'group delete '*)
            [[ $(jq length "$WORK_DIR/resources.json") == 0 ]] || return 99
            touch "$WORK_DIR/group-deleted"
            printf 'null\n' ;;
        'network vnet create'|'network nsg create'|'network public-ip create'|'network nic create')
            name=$(arg --name "$@")
            case "$action" in
                'network vnet create') type=Microsoft.Network/virtualNetworks ;;
                'network nsg create') type=Microsoft.Network/networkSecurityGroups ;;
                'network public-ip create') type=Microsoft.Network/publicIPAddresses ;;
                'network nic create') type=Microsoft.Network/networkInterfaces ;;
            esac
            add_resource "$type" "$name"
            printf '{}\n' ;;
        'network vnet subnet')
            if [[ $4 == show ]]; then
                jq -n --arg cidr "$SUBNET_CIDR" '{addressPrefix:$cidr,defaultOutboundAccess:false}'
            else printf '{}\n'; fi ;;
        'network nsg rule')
            printf '{}\n' ;;
        'vm create '*)
            [[ $(arg --ssh-key-values "$@") == "$SSH_KEY" ]] || return 98
            [[ $(arg --priority "$@") == Regular ]] || return 98
            [[ $(arg --storage-sku "$@") == StandardSSD_LRS ]] || return 98
            [[ $(arg --os-disk-delete-option "$@") == Detach ]] || return 98
            [[ $(arg --nic-delete-option "$@") == Detach ]] || return 98
            if [[ $SCENARIO == create-failure || $SCENARIO == retain-failure ]]; then
                printf 'simulated VM allocation failure\n' >&2
                return 42
            fi
            add_resource Microsoft.Compute/virtualMachines "$VM"
            add_resource Microsoft.Compute/disks "$DISK" ''
            if [[ $SCENARIO == foreign-resource ]]; then add_resource Microsoft.Network/virtualNetworks foreign OTHER; fi
            if [[ $SCENARIO == foreign-subnet ]]; then
                jq 'map(if .type=="Microsoft.Network/virtualNetworks" then .properties.subnets += [{name:"foreign"}] else . end)' \
                    "$WORK_DIR/resources.json" >"$WORK_DIR/updated.json"
                mv "$WORK_DIR/updated.json" "$WORK_DIR/resources.json"
            fi
            if [[ $SCENARIO == policy-extras ]]; then add_resource Microsoft.RecoveryServices/vaults policy-vault OTHER; fi
            printf '{}\n' ;;
        'vm show '*)
            vm_model ;;
        'disk show '*)
            jq -n --argjson gb "$DISK_GB" '{creationData:{createOption:"FromImage"},sku:{name:"StandardSSD_LRS"},diskSizeGb:$gb,osType:"Linux"}' ;;
        'tag update '*)
            id=$(arg --resource-id "$@")
            jq --arg id "$id" --arg run "$RUN_ID" 'map(if .id==$id then .tags.vpnProvisionRun=$run else . end)' \
                "$WORK_DIR/resources.json" >"$WORK_DIR/updated.json"
            mv "$WORK_DIR/updated.json" "$WORK_DIR/resources.json"
            printf '{}\n' ;;
        'vm auto-shutdown '*)
            [[ " $* " == *' --off '* ]] || return 98
            printf 'null\n' ;;
        'network public-ip show')
            jq -n --arg id "$(resource_id Microsoft.Network/publicIPAddresses "$PIP")" \
                '{id:$id,sku:{name:"Standard"},publicIPAllocationMethod:"Static",publicIPAddressVersion:"IPv4",ipAddress:"203.0.113.10",zones:["1","2","3"]}' ;;
        'network nsg show')
            jq -n --arg id "$(resource_id Microsoft.Network/networkSecurityGroups "$NSG")" --arg protocol "$PROTOCOL" --arg port "$VPN_PORT" '
                {id:$id,securityRules:[
                {name:"AllowSSH",protocol:"Tcp",destinationPortRange:"22",priority:100,access:"Allow",direction:"Inbound",sourceAddressPrefix:"0.0.0.0/0",sourcePortRange:"*",destinationAddressPrefix:"*"},
                {name:"AllowVPN",protocol:$protocol,destinationPortRange:$port,priority:110,access:"Allow",direction:"Inbound",sourceAddressPrefix:"0.0.0.0/0",sourcePortRange:"*",destinationAddressPrefix:"*"}]}' ;;
        'network nic show')
            jq -n --arg nsg "$(resource_id Microsoft.Network/networkSecurityGroups "$NSG")" \
                --arg ip "$(resource_id Microsoft.Network/publicIPAddresses "$PIP")" \
                '{networkSecurityGroup:{id:$nsg},ipConfigurations:[{privateIPAddressVersion:"IPv4",publicIPAddress:{id:$ip}}]}' ;;
        'resource list '*)
            if [[ $(arg --resource-type "$@") == Microsoft.DevTestLab/schedules ]]; then
                if [[ $SCENARIO == enabled-schedule || $SCENARIO == disabled-schedule ]]; then
                    printf '[{"id":"schedule"}]\n'
                else printf '[]\n'; fi
            else cat "$WORK_DIR/resources.json"; fi ;;
        'resource show '*)
            id=$(arg --ids "$@")
            if [[ $id == schedule ]]; then
                local status=Enabled
                [[ $SCENARIO != disabled-schedule ]] || status=Disabled
                jq -n --arg vm "$(resource_id Microsoft.Compute/virtualMachines "$VM")" --arg status "$status" \
                    '{properties:{targetResourceId:$vm,status:$status}}'
            else jq --arg id "$id" '.[] | select(.id==$id)' "$WORK_DIR/resources.json"; fi ;;
        'resource delete '*)
            id=$(arg --ids "$@")
            jq --arg id "$id" 'map(select(.id!=$id))' "$WORK_DIR/resources.json" >"$WORK_DIR/updated.json"
            mv "$WORK_DIR/updated.json" "$WORK_DIR/resources.json"
            printf 'null\n' ;;
        *) printf 'UNEXPECTED AZURE COMMAND: %s\n' "$*" >&2; return 97 ;;
    esac
}

curl() {
    [[ $SCENARIO != no-prices ]] || return 22
    if [[ $SCENARIO == malformed-prices ]]; then printf '{"error":"unavailable"}\n'; return; fi
    if [[ $* == *page2* ]]; then
        printf '{"Items":[],"NextPageLink":null}\n'
        return
    fi
    cat <<'JSON'
{"Items":[
 {"armSkuName":"Standard_B1s","armRegionName":"westus2","type":"Consumption","currencyCode":"USD","unitOfMeasure":"1 Hour","retailPrice":0.01,"isPrimaryMeterRegion":true,"productName":"Virtual Machines BS Series","skuName":"B1s","meterName":"B1s"},
 {"armSkuName":"Standard_B2pts_v2","armRegionName":"westus2","type":"Consumption","currencyCode":"USD","unitOfMeasure":"1 Hour","retailPrice":0.005,"isPrimaryMeterRegion":true,"productName":"Virtual Machines Bps v2 Series","skuName":"B2pts v2","meterName":"B2pts v2"},
 {"armSkuName":"Standard_B1s","armRegionName":"westus2","type":"Consumption","currencyCode":"USD","unitOfMeasure":"1 Hour","retailPrice":0.0001,"isPrimaryMeterRegion":true,"productName":"Virtual Machines BS Series Windows","skuName":"B1s Spot","meterName":"B1s Spot"},
 {"armSkuName":"Standard_B1s","armRegionName":"westus2","type":"Consumption","currencyCode":"USD","unitOfMeasure":"1 Hour","retailPrice":0.0002,"isPrimaryMeterRegion":false,"productName":"Virtual Machines BS Series","skuName":"B1s","meterName":"B1s"}
],"NextPageLink":"https://prices.azure.com:443/api/retail/prices?page2"}
JSON
}

feed() {
    if [[ $SCENARIO == eof ]]; then printf '%s\n' 1 rg; return; fi
    printf '%s\n' 1 rg vpn01 '' "${TEST_VPN:-wireguard}"
    if [[ ${TEST_VPN:-wireguard} == openvpn ]]; then printf '%s\n' tcp; fi
    if [[ $SCENARIO == invalid-prompts ]]; then printf '%s\n' 65536 51821; else printf '%s\n' ''; fi
    printf '%s\n' '' '' ''
    case "$SCENARIO" in
        no-prices|malformed-prices) printf '%s\n' Standard_Mismatch Standard_B1s ;;
        manual) printf '%s\n' m Standard_B1s ;;
        *) printf '%s\n' 1 ;;
    esac
    if [[ $SCENARIO == invalid-prompts ]]; then printf '%s\n' 1 64; else printf '%s\n' ''; fi
    if [[ $SCENARIO == cancel ]]; then printf '%s\n' no; else printf '%s\n' yes; fi
    case "$SCENARIO" in
        create-failure|bad-key|foreign-resource|foreign-subnet|changed-delete-options|policy-extras) printf '%s\n' yes ;;
        *) printf '%s\n' no ;;
    esac
}

worker() {
    source "$ROOT/create-vpn-vm.sh"
    WORK_DIR=$CASE_DIR RUN_ID=0123456789abcdef0123456789abcdef
    printf '[]\n' >"$WORK_DIR/resources.json"
    : >"$WORK_DIR/calls"
    trap 'handle_failure "$?" "$LINENO"' ERR
    workflow
}

if [[ ${1-} == --worker ]]; then
    worker
    exit
fi

for tool in bash jq; do command -v "$tool" >/dev/null || { printf 'Missing test prerequisite: %s\n' "$tool" >&2; exit 1; }; done
bash -n "$ROOT/create-vpn-vm.sh" "$ROOT/tests/run.sh"
source "$ROOT/create-vpn-vm.sh"
valid_group 'vpn-rg(1)' && ! valid_group '-bad' && ! valid_group 'bad.'
valid_vm vpn01 && ! valid_vm 'bad-' && ! valid_vm 'bad name'
valid_user sjp && ! valid_user root && ! valid_user '-oops'
valid_port 51820 && valid_port 00022 && ! valid_port 0 && ! valid_port 65536
valid_networks 10.80.0.0/16 10.80.1.0/24
! valid_networks 10.80.0.0/16 10.81.0.0/24
! valid_networks 10.80.0.1/16 10.80.0.0/24
! valid_networks 8.0.0.0/8 8.1.0.0/24
printf 'PASS input validation\n'

failures=0
for scenario in success openvpn manual no-prices malformed-prices invalid-prompts disabled-schedule cancel eof collision no-image \
    create-failure retain-failure bad-key enabled-schedule foreign-resource foreign-subnet changed-delete-options policy-extras; do
    CASE_DIR=$(mktemp -d)
    export CASE_DIR
    TEST_VPN=wireguard
    [[ $scenario != openvpn ]] || TEST_VPN=openvpn
    export TEST_VPN
    SCENARIO=$scenario
    status=0
    feed | bash "$ROOT/tests/run.sh" --worker "$scenario" >"$CASE_DIR/output" 2>&1 || status=$?
    ok=true
    case "$scenario" in
        success|openvpn|manual|no-prices|malformed-prices|invalid-prompts|disabled-schedule)
            [[ $status == 0 ]] && grep -Fq 'Infrastructure ready.' "$CASE_DIR/output" || ok=false
            grep -Fq -- "$SSH_KEY" "$CASE_DIR/calls" || ok=false
            grep -Fq 'vm auto-shutdown ' "$CASE_DIR/calls" || ok=false
            if grep -Eq 'backup|snapshot|--generate-ssh-keys|--use-unmanaged-disk|--priority Spot' "$CASE_DIR/calls"; then ok=false; fi
            case "$scenario" in
                success)
                    jq -e '.name=="Standard_B2pts_v2" and .price==0.005 and .image.architecture=="Arm64"' \
                        < <(jq '.[0]' "$CASE_DIR/shortlist.json") >/dev/null || ok=false ;;
                openvpn) grep -Fq -- '--protocol Tcp' "$CASE_DIR/calls" || ok=false ;;
                no-prices) grep -Fq 'no usable priced shortlist' "$CASE_DIR/output" || ok=false ;;
                invalid-prompts)
                    grep -Fq -- '--os-disk-size-gb 64' "$CASE_DIR/calls" &&
                        grep -Fq -- '--destination-port-ranges 51821' "$CASE_DIR/calls" || ok=false ;;
            esac ;;
        cancel)
            [[ $status == 0 ]] && [[ ! -f $CASE_DIR/group-created ]] || ok=false ;;
        collision|no-image|eof)
            [[ $status != 0 ]] && [[ ! -f $CASE_DIR/group-created ]] || ok=false ;;
        create-failure|bad-key)
            [[ $status != 0 && -f $CASE_DIR/group-deleted ]] || ok=false ;;
        retain-failure|enabled-schedule)
            [[ $status != 0 && ! -f $CASE_DIR/group-deleted ]] &&
                [[ $(jq length "$CASE_DIR/resources.json") -gt 0 ]] || ok=false ;;
        foreign-resource)
            [[ $status != 0 && ! -f $CASE_DIR/group-deleted ]] &&
                jq -e 'any(.[]; .name=="foreign" and .tags.vpnProvisionRun=="OTHER")' "$CASE_DIR/resources.json" >/dev/null || ok=false ;;
        foreign-subnet)
            [[ $status != 0 && ! -f $CASE_DIR/group-deleted ]] &&
                jq -e 'any(.[]; .type=="Microsoft.Network/virtualNetworks" and any(.properties.subnets[]; .name=="foreign"))' \
                    "$CASE_DIR/resources.json" >/dev/null || ok=false ;;
        changed-delete-options)
            [[ $status != 0 && ! -f $CASE_DIR/group-deleted ]] &&
                ! grep -Fq 'resource delete ' "$CASE_DIR/calls" || ok=false ;;
        policy-extras)
            [[ $status != 0 && ! -f $CASE_DIR/group-deleted ]] &&
                jq -e 'any(.[]; .name=="policy-vault" and .tags.vpnProvisionRun=="OTHER")' "$CASE_DIR/resources.json" >/dev/null || ok=false ;;
    esac
    if [[ $ok == true ]]; then
        printf 'PASS %s\n' "$scenario"
    else
        printf 'FAIL %s (status %s)\n' "$scenario" "$status"
        cat "$CASE_DIR/output"
        failures=$((failures+1))
    fi
    rm -f -- "$CASE_DIR"/*
    rmdir -- "$CASE_DIR"
done

if bash "$ROOT/create-vpn-vm.sh" </dev/null >/dev/null 2>&1; then
    printf 'FAIL noninteractive terminal rejection\n'
    failures=$((failures+1))
else printf 'PASS noninteractive terminal rejection\n'; fi
(( failures == 0 ))
