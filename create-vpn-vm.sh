#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SSH_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4l1+Vz1OgxgiyVcdxGXYdqMPIeY2BY9TaafOuMx2rj'
SUBSCRIPTION='' RG='' VM='' RUN_ID='' WORK_DIR=''
MUTATION_STARTED=false COMPLETED=false HANDLING_FAILURE=false

say() { printf '%s\n' "$*" >&2; }
die() { say "ERROR: $*"; return 1; }

prompt() {
    local variable=$1 label=$2 default=${3-} input_value
    if [[ -n $default ]]; then label+=" [$default]"; fi
    if ! IFS= read -r -p "$label: " input_value; then
        say 'Input ended; stopping.'
        return 1
    fi
    printf -v "$variable" '%s' "${input_value:-$default}"
}

confirm() {
    local answer
    prompt answer "$1 (type yes to continue)" no || return 1
    [[ ${answer,,} == yes ]]
}

az_call() {
    local mode=$1 attempt=1 output status
    shift
    local -a scope=()
    if [[ -n $SUBSCRIPTION ]]; then scope=(--subscription "$SUBSCRIPTION"); fi
    while :; do
        if output=$(az "$@" "${scope[@]}" --only-show-errors --output json 2>"$WORK_DIR/az-error"); then
            if [[ -n $output ]]; then
                jq empty <<<"$output" || { say 'Azure CLI returned invalid JSON.'; return 1; }
                printf '%s\n' "$output"
            else
                printf 'null\n'
            fi
            return 0
        else
            status=$?
        fi
        if [[ $mode == read && $attempt -lt 3 ]] &&
            grep -Eqi 'TooManyRequests|Throttl|ServiceUnavailable|InternalServerError|GatewayTimeout|temporar|timed out|ConnectionError' "$WORK_DIR/az-error"; then
            sleep "$attempt"
            attempt=$((attempt + 1))
        else
            cat "$WORK_DIR/az-error" >&2
            return "$status"
        fi
    done
}

az_read() { az_call read "$@"; }
az_write() { az_call write "$@"; }

valid_group() {
    [[ ${#1} -le 90 && $1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.\(\)-]*$ && $1 != *. ]]
}

valid_vm() {
    [[ ${#1} -le 64 && $1 =~ ^[a-zA-Z][a-zA-Z0-9-]*$ && $1 != *- ]]
}

valid_user() {
    [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    case "$1" in
        root|admin|administrator|user|user1|user2|user3|user4|user5|test|test1|test2|test3|guest|support|\
        sysadmin|admin1|admin2|actuser|adm|aspnet|backup|console|david|john|owner|server|sql|sys|support_388945a0|a)
            return 1 ;;
    esac
}

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

parse_cidr() {
    local cidr=$1 a b c d prefix value mask
    [[ $cidr =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]} prefix=${BASH_REMATCH[5]}
    a=$((10#$a)) b=$((10#$b)) c=$((10#$c)) d=$((10#$d)) prefix=$((10#$prefix))
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 && prefix >= 8 && prefix <= 29 )) || return 1
    value=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
    (( (value & mask) == value )) || return 1
    # A standalone private VNet avoids accidentally allocating public address space.
    (( (a == 10 && prefix >= 8) ||
       (a == 172 && b >= 16 && b <= 31 && prefix >= 12) ||
       (a == 192 && b == 168 && prefix >= 16) )) || return 1
    CIDR_NET=$value CIDR_MASK=$mask CIDR_PREFIX=$prefix
}

valid_networks() {
    local network mask prefix
    parse_cidr "$1" || return 1
    network=$CIDR_NET mask=$CIDR_MASK prefix=$CIDR_PREFIX
    parse_cidr "$2" || return 1
    (( CIDR_PREFIX >= prefix && (CIDR_NET & mask) == network ))
}

choose_subscription() {
    local accounts count index
    if ! accounts=$(az_read account list --all); then accounts='[]'; fi
    accounts=$(jq '[.[] | select(.state == "Enabled")]' <<<"$accounts")
    if [[ $(jq length <<<"$accounts") == 0 ]]; then
        say 'Sign in to Azure using the normal interactive Azure CLI login flow.'
        az_write login >/dev/null
        accounts=$(az_read account list --all)
        accounts=$(jq '[.[] | select(.state == "Enabled")]' <<<"$accounts")
    fi
    count=$(jq length <<<"$accounts")
    (( count > 0 )) || die 'No enabled Azure subscriptions are available.'
    jq -r 'to_entries[] | "\(.key+1)) \(.value.name)  \(.value.id)  tenant=\(.value.tenantId)"' <<<"$accounts" >&2
    while :; do
        prompt index 'Subscription number' 1
        if [[ $index =~ ^[0-9]{1,6}$ ]] && (( 10#$index >= 1 && 10#$index <= count )); then break; fi
        say 'Choose a subscription number from the list.'
    done
    SUBSCRIPTION=$(jq -r --argjson i "$((10#$index - 1))" '.[$i].id' <<<"$accounts")
}

collect_inputs() {
    local locations exists
    while :; do
        prompt RG 'New resource group name'
        valid_group "$RG" && break
        say 'Use 1-90 letters, digits, underscores, hyphens, periods or parentheses; no trailing period.'
    done
    exists=$(az_read group exists --name "$RG")
    [[ $exists == false ]] || die "Resource group '$RG' already exists; nothing will be modified."
    while :; do
        prompt VM 'VM name'
        valid_vm "$VM" && break
        say 'Use 1-64 letters, digits or hyphens; start with a letter and do not end with a hyphen.'
    done
    locations=$(az_read account list-locations)
    while :; do
        prompt LOCATION 'Azure region' westus2
        LOCATION=${LOCATION,,}
        jq -e --arg name "$LOCATION" 'any(.[]; .name == $name)' <<<"$locations" >/dev/null && break
        say 'Enter an Azure region identifier, for example westus2.'
    done
    while :; do
        prompt VPN 'VPN type (wireguard/openvpn)' wireguard
        VPN=${VPN,,}
        [[ $VPN == wireguard || $VPN == openvpn ]] && break
        say 'Choose wireguard or openvpn.'
    done
    PROTOCOL=Udp
    if [[ $VPN == openvpn ]]; then
        while :; do
            prompt transport 'OpenVPN transport (udp/tcp)' udp
            case "${transport,,}" in
                udp) PROTOCOL=Udp; break ;;
                tcp) PROTOCOL=Tcp; break ;;
                *) say 'Choose udp or tcp.' ;;
            esac
        done
        PORT_DEFAULT=1194
    else
        PORT_DEFAULT=51820
    fi
    while :; do
        prompt VPN_PORT 'VPN port' "$PORT_DEFAULT"
        if valid_port "$VPN_PORT"; then
            VPN_PORT=$((10#$VPN_PORT))
            if [[ $PROTOCOL != Tcp || $VPN_PORT != 22 ]]; then break; fi
            say 'TCP 22 is reserved for SSH; choose a different VPN port.'
        else
            say 'Enter a port from 1 to 65535.'
        fi
    done
    while :; do
        prompt ADMIN 'SSH administrator username' sjp
        valid_user "$ADMIN" && break
        say 'Use a nonreserved Linux username, up to 32 lowercase letters, digits, underscores or hyphens.'
    done
    while :; do
        prompt VNET_CIDR 'Private VNet IPv4 CIDR' '10.80.0.0/16'
        prompt SUBNET_CIDR 'Subnet IPv4 CIDR inside that VNet' '10.80.0.0/24'
        valid_networks "$VNET_CIDR" "$SUBNET_CIDR" && break
        say 'Use aligned RFC1918 IPv4 network ranges (/8 to /29), with the subnet inside the VNet.'
    done
    VNET="${VM}-vnet" SUBNET="${VM}-subnet" NSG="${VM}-nsg"
    NIC="${VM}-nic" PIP="${VM}-ip" DISK="${VM}-os"
}

discover_images() {
    local skus sku detail record
    IMAGES='[]'
    skus=$(az_read vm image list-skus --location "$LOCATION" --publisher Debian --offer debian-12)
    while IFS= read -r sku; do
        if ! detail=$(az_read vm image show --location "$LOCATION" --urn "Debian:debian-12:$sku:latest"); then
            say "Could not inspect Debian 12 SKU '$sku'; excluding it."
            continue
        fi
        record=$(jq -c --arg sku "$sku" '
            select(.osDiskImage.operatingSystem == "Linux" and .plan == null)
            | select(.architecture == "x64" or .architecture == "Arm64")
            | select(.hyperVGeneration == "V1" or .hyperVGeneration == "V2")
            | select(.name | test("^[0-9]+(\\.[0-9]+)+$"))
            | select(.osDiskImage.sizeInGb > 0)
            | {urn: ("Debian:debian-12:" + $sku + ":" + .name),
               architecture: .architecture, generation: .hyperVGeneration,
               minDisk: .osDiskImage.sizeInGb,
               controllers: ([.features[]? | select(.name == "DiskControllerTypes") | .value][0] // "SCSI")}
        ' <<<"$detail")
        if [[ -n $record ]]; then IMAGES=$(jq -c --argjson item "$record" '. + [$item]' <<<"$IMAGES"); fi
    done < <(jq -r '.[].name' <<<"$skus")
    [[ $(jq length <<<"$IMAGES") != 0 ]] || die "No compatible official Debian 12 images found in $LOCATION."
    printf '%s\n' "$IMAGES" >"$WORK_DIR/images.json"
}

discover_sizes() {
    local usage
    az_read vm list-skus --location "$LOCATION" --resource-type virtualMachines --all >"$WORK_DIR/skus.json"
    if ! usage=$(az_read vm list-usage --location "$LOCATION"); then
        say 'WARNING: quota lookup unavailable; Azure will enforce quota at deployment.'
        usage='[]'
    fi
    printf '%s\n' "$usage" >"$WORK_DIR/usage.json"
    jq -n --slurpfile skus "$WORK_DIR/skus.json" --slurpfile images "$WORK_DIR/images.json" \
        --slurpfile usage "$WORK_DIR/usage.json" '
        def cap: [.capabilities[] | {key: .name, value: .value}] | from_entries;
        def fitsquota($family; $cores):
            all($usage[0][] | select((.name.value|ascii_downcase) == ($family|ascii_downcase)
                or (.name.value|ascii_downcase) == "cores"); .currentValue + $cores <= .limit);
        [$skus[0][] | select(.resourceType == "virtualMachines")
         | select((.restrictions // [] | length) == 0)
         | . as $sku | cap as $c
         | select($c.vCPUs != null and $c.MemoryGB != null and $c.CpuArchitecture != null)
         | select(fitsquota($sku.family; ($c.vCPUs|tonumber)))
         | ([$images[0][] | . as $image
             | select((.architecture|ascii_downcase) == ($c.CpuArchitecture|ascii_downcase))
             | select(($c.HyperVGenerations // "" | split(",") | map(gsub(" "; ""))) | index($image.generation))
             | select(any((($c.DiskControllerTypes // "SCSI") | split(","))[];
                 . as $controller | ($image.controllers | split(",") | index($controller)) != null))]
             | sort_by(.generation, .urn) | last) as $compatible
         | select($compatible != null)
         | {name: $sku.name, family: $sku.family, vcpus: ($c.vCPUs|tonumber),
            ram: ($c.MemoryGB|tonumber), image: $compatible,
            burstable: ($sku.name | test("^Standard_B"; "i"))}]
        ' >"$WORK_DIR/eligible.json"
    [[ $(jq length "$WORK_DIR/eligible.json") != 0 ]] ||
        die 'No compatible Debian 12 VM sizes with known capabilities and sufficient reported quota were found.'
}

fetch_prices() {
    local url='https://prices.azure.com/api/retail/prices' page next
    : >"$WORK_DIR/prices.ndjson"
    if ! curl --fail --silent --show-error --proto '=https' --connect-timeout 10 --max-time 60 --retry 2 \
        --get --data-urlencode 'currencyCode=USD' \
        --data-urlencode "\$filter=serviceName eq 'Virtual Machines' and armRegionName eq '$LOCATION' and priceType eq 'Consumption'" \
        "$url" >"$WORK_DIR/price-page.json"; then return 1; fi
    while :; do
        page=$(cat "$WORK_DIR/price-page.json")
        jq -e '.Items | type == "array"' <<<"$page" >/dev/null || return 1
        jq -c '.Items[]' <<<"$page" >>"$WORK_DIR/prices.ndjson"
        next=$(jq -r '.NextPageLink // empty' <<<"$page")
        [[ -n $next ]] || break
        [[ $next == https://prices.azure.com/api/retail/prices\?* ||
           $next == https://prices.azure.com:443/api/retail/prices\?* ]] || return 1
        [[ $next != "$url" ]] || return 1
        url=$next
        if ! curl --fail --silent --show-error --proto '=https' --connect-timeout 10 --max-time 60 --retry 2 \
            "$next" >"$WORK_DIR/price-page.json"; then return 1; fi
    done
    jq -s '.' "$WORK_DIR/prices.ndjson" >"$WORK_DIR/prices.json"
}

build_shortlist() {
    jq -n --arg region "$LOCATION" --slurpfile sizes "$WORK_DIR/eligible.json" \
        --slurpfile prices "$WORK_DIR/prices.json" '
        [$prices[0][] | select(.type == "Consumption" and .currencyCode == "USD")
         | select(.armRegionName == $region and .unitOfMeasure == "1 Hour" and .retailPrice > 0)
         | select(.isPrimaryMeterRegion == true)
         | select((.productName + " " + .skuName + " " + .meterName)
             | test("Windows|Spot|Low Priority|Cloud Services|Dedicated Host|Red Hat|RHEL|SUSE|Ubuntu Pro|SQL|Oracle|BizTalk"; "i") | not)
         | {name: .armSkuName, price: .retailPrice}]
         | group_by(.name) | map(min_by(.price)) as $meters
         | [$sizes[0][] | select(.vcpus <= 4 and .ram <= 8 and .ram >= 0.5)
             | . as $size | $meters[] | select(.name == $size.name)
             | $size + {price: .price}]
         | sort_by(.price, .name) | .[:6]
    ' >"$WORK_DIR/shortlist.json"
}

choose_size() {
    local selection count selected minimum
    if fetch_prices && build_shortlist && [[ $(jq length "$WORK_DIR/shortlist.json") != 0 ]]; then
        count=$(jq length "$WORK_DIR/shortlist.json")
        say 'Low-cost compatible choices (public USD retail, compute only; monthly = 730 hours):'
        jq -r 'to_entries[] | "\(.key+1)) \(.value.name)  \(.value.image.architecture)  \(.value.vcpus) vCPU  \(.value.ram) GiB  $\(.value.price)/hour  $\((.value.price*730*100|round)/100)/month\(if .value.burstable then "  BURSTABLE" else "" end)"' \
            "$WORK_DIR/shortlist.json" >&2
        say 'Disk, public IPv4, disk operations, outbound traffic and tax are extra. Actual rates may differ.'
        say 'Burstable VMs have CPU-credit limits; specifications do not guarantee VPN throughput.'
        while :; do
            prompt selection 'VM choice number, or m to enter a size manually' 1
            if [[ ${selection,,} == m ]]; then break; fi
            if [[ $selection =~ ^[0-9]{1,6}$ ]] && (( 10#$selection >= 1 && 10#$selection <= count )); then
                selected=$(jq -c --argjson i "$((10#$selection - 1))" '.[$i]' "$WORK_DIR/shortlist.json")
                break
            fi
            say 'Choose a listed number or m.'
        done
    else
        say 'WARNING: no usable priced shortlist is available. Enter a VM size explicitly; no estimate will be claimed.'
    fi
    if [[ -z ${selected-} ]]; then
        while :; do
            prompt SIZE 'Exact VM size (for example Standard_B1s)'
            selected=$(jq -c --arg name "$SIZE" '.[] | select(.name == $name)' "$WORK_DIR/eligible.json")
            [[ -n $selected ]] && break
            say 'That size is unavailable, restricted, over reported quota, or incompatible with the Debian 12 images.'
        done
    fi
    SELECTED=$selected
    SIZE=$(jq -r .name <<<"$selected")
    IMAGE=$(jq -r .image.urn <<<"$selected")
    ARCH=$(jq -r .image.architecture <<<"$selected")
    minimum=$(jq -r .image.minDisk <<<"$selected")
    while :; do
        prompt DISK_GB 'OS disk GiB (Standard SSD LRS; billed in capacity tiers)' "$minimum"
        if [[ $DISK_GB =~ ^[0-9]{1,5}$ ]] && (( 10#$DISK_GB >= minimum && 10#$DISK_GB <= 32767 )); then
            DISK_GB=$((10#$DISK_GB))
            break
        fi
        say "Choose an integer from the image minimum ($minimum) to 32767 GiB."
    done
}

deployment_summary() {
    say "
Deployment summary
  Subscription: $SUBSCRIPTION
  NEW resource group: $RG
  VM / region: $VM / $LOCATION
  Size / architecture: $SIZE / $ARCH
  Pinned image: $IMAGE
  OS disk: $DISK, ${DISK_GB} GiB, StandardSSD_LRS (local replication)
  Administrator: $ADMIN; fixed ED25519 key; password SSH disabled
  Network: $VNET ($VNET_CIDR), $SUBNET ($SUBNET_CIDR)
  NSG / NIC / static Standard public IPv4: $NSG / $NIC / $PIP
  Inbound: TCP 22 and $PROTOCOL $VPN_PORT from 0.0.0.0/0
  VPN preset: $VPN; VPN SOFTWARE WILL NOT BE INSTALLED
  Regular on-demand; no Spot, backups, extra disks or optional HA
  Auto-shutdown: disabled (external automation/policies can still stop a VM)"
    if jq -e 'has("price")' <<<"$SELECTED" >/dev/null; then
        jq -r '"  Compute estimate: $\(.price)/hour; $\((.price*730*100|round)/100)/730-hour month, USD retail"' <<<"$SELECTED" >&2
    else
        say '  Compute price: unavailable / manually selected; no estimate.'
    fi
    say '  Disk, disk operations, public IPv4, traffic and tax: additional; not included in compute estimate.'
}

owned() {
    jq -e --arg run "$RUN_ID" '.tags.vpnProvisionRun == $run' >/dev/null
}

inventory() {
    az_read resource list --resource-group "$RG"
}

cleanup_created() {
    local resources id type detail group current vm_current
    resources=$(inventory) || { say 'Cannot obtain inventory; no cleanup attempted.'; return 1; }
    say 'Current resource inventory (only matching run ownership tags are eligible for deletion):'
    jq -r --arg run "$RUN_ID" '.[] | "\(if .tags.vpnProvisionRun == $run then "OWNED" else "RETAIN" end) \(.id)"' <<<"$resources" >&2
    confirm 'Delete only resources verified as created by this run?' || { say 'Resources retained.'; return 0; }
    # Delete dependents before their network dependencies. Unknown resource types are retained.
    for type in microsoft.compute/virtualmachines microsoft.compute/disks microsoft.network/networkinterfaces \
        microsoft.network/publicipaddresses microsoft.network/networksecuritygroups microsoft.network/virtualnetworks; do
        while IFS= read -r id; do
            if ! detail=$(az_read resource show --ids "$id"); then
                say "Could not verify ownership; retaining $id"
                continue
            fi
            if ! owned <<<"$detail"; then say "Ownership changed; retaining $id"; continue; fi
            current=$(inventory) || { say 'Inventory failed; stopping cleanup.'; return 1; }
            if jq -e --arg prefix "${id,,}/" --arg run "$RUN_ID" '
                any(.[]; (.id|ascii_downcase|startswith($prefix)) and .tags.vpnProvisionRun != $run)
            ' <<<"$current" >/dev/null; then
                say "Unowned child resource exists; retaining $id"
                continue
            fi
            if [[ $type == microsoft.compute/virtualmachines ]]; then
                # VM-owned disk/NIC delete options are Detach, preventing cascading deletions.
                vm_current=$(az_read vm show --resource-group "$RG" --name "$VM") || return 1
                if ! jq -e 'all(.storageProfile.dataDisks[]?; .deleteOption == "Detach")
                    and .storageProfile.osDisk.deleteOption == "Detach"
                    and all(.networkProfile.networkInterfaces[]; (.deleteOption // .properties.deleteOption) == "Detach")' \
                    <<<"$vm_current" >/dev/null; then
                    say 'VM delete options changed; retaining the VM and its dependencies.'
                    return 1
                fi
            elif [[ $type == microsoft.network/virtualnetworks ]]; then
                if ! jq -e --arg subnet "$SUBNET" '(.properties.subnets|type) == "array"
                    and all(.properties.subnets[]; .name == $subnet)' <<<"$detail" >/dev/null; then
                    say 'VNet contains unexpected subnets; retaining it.'
                    continue
                fi
            fi
            if ! az_write resource delete --ids "$id" >/dev/null; then say "Could not delete $id; retaining it."; fi
        done < <(jq -r --arg run "$RUN_ID" --arg type "$type" \
            '.[] | select(.tags.vpnProvisionRun == $run and (.type|ascii_downcase) == $type) | .id' <<<"$resources")
    done
    resources=$(inventory) || return 1
    group=$(az_read group show --name "$RG") || return 1
    if [[ $(jq length <<<"$resources") == 0 ]] && owned <<<"$group"; then
        if az_write group delete --name "$RG" --yes >/dev/null; then
            say 'Empty run-owned resource group deleted.'
        else
            say 'Could not delete the empty resource group.'
            return 1
        fi
    else
        say 'Resource group retained because it is nonempty or ownership could not be verified.'
        jq -r '.[].id' <<<"$resources" >&2
    fi
}

handle_failure() {
    local status=$1 line=$2
    if (( BASH_SUBSHELL > 0 )); then exit "$status"; fi
    if [[ $HANDLING_FAILURE == true ]]; then exit "$status"; fi
    HANDLING_FAILURE=true
    trap - ERR INT TERM
    set +e
    say "Stopped (status $status, line $line)."
    if [[ $MUTATION_STARTED == true && $COMPLETED == false ]]; then
        say "Resources may remain in '$RG'. Run ownership marker: $RUN_ID"
        if ! cleanup_created; then
            say "Cleanup incomplete. Inspect resource group '$RG'; no further automatic deletion will occur."
        fi
    fi
    exit "$status"
}

create_infrastructure() {
    local exists group disk_model
    exists=$(az_read group exists --name "$RG")
    [[ $exists == false ]] || die 'Resource group appeared after preflight; refusing to continue.'
    MUTATION_STARTED=true
    group=$(az_write group create --name "$RG" --location "$LOCATION" --tags "vpnProvisionRun=$RUN_ID")
    owned <<<"$group" || die 'Created resource group ownership could not be verified.'
    [[ $(inventory | jq length) == 0 ]] || die 'New resource group is not empty; refusing to adopt existing resources.'
    az_write network vnet create --resource-group "$RG" --location "$LOCATION" --name "$VNET" \
        --address-prefixes "$VNET_CIDR" --tags "vpnProvisionRun=$RUN_ID" >/dev/null
    az_write network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET" \
        --address-prefixes "$SUBNET_CIDR" --default-outbound-access false >/dev/null
    az_write network nsg create --resource-group "$RG" --location "$LOCATION" --name "$NSG" \
        --tags "vpnProvisionRun=$RUN_ID" >/dev/null
    az_write network nsg rule create --resource-group "$RG" --nsg-name "$NSG" --name AllowSSH \
        --priority 100 --direction Inbound --access Allow --protocol Tcp \
        --source-address-prefixes '0.0.0.0/0' --source-port-ranges '*' \
        --destination-address-prefixes '*' --destination-port-ranges 22 >/dev/null
    az_write network nsg rule create --resource-group "$RG" --nsg-name "$NSG" --name AllowVPN \
        --priority 110 --direction Inbound --access Allow --protocol "$PROTOCOL" \
        --source-address-prefixes '0.0.0.0/0' --source-port-ranges '*' \
        --destination-address-prefixes '*' --destination-port-ranges "$VPN_PORT" >/dev/null
    az_write network public-ip create --resource-group "$RG" --location "$LOCATION" --name "$PIP" \
        --sku Standard --allocation-method Static --version IPv4 --tags "vpnProvisionRun=$RUN_ID" >/dev/null
    az_write network nic create --resource-group "$RG" --location "$LOCATION" --name "$NIC" \
        --vnet-name "$VNET" --subnet "$SUBNET" --network-security-group "$NSG" \
        --public-ip-address "$PIP" --tags "vpnProvisionRun=$RUN_ID" >/dev/null
    inventory | jq -e --arg run "$RUN_ID" --arg vm "$VM" --arg disk "$DISK" '
        all(.[]; .tags.vpnProvisionRun == $run and .name != $vm and .name != $disk)
    ' >/dev/null || die 'Unexpected or conflicting resources appeared before VM creation.'
    az_write vm create --resource-group "$RG" --location "$LOCATION" --name "$VM" --size "$SIZE" \
        --image "$IMAGE" --admin-username "$ADMIN" --authentication-type ssh --ssh-key-values "$SSH_KEY" \
        --nics "$NIC" --nsg-rule NONE --os-disk-name "$DISK" --os-disk-size-gb "$DISK_GB" \
        --storage-sku StandardSSD_LRS --priority Regular --security-type Standard \
        --os-disk-delete-option Detach --nic-delete-option Detach --tags "vpnProvisionRun=$RUN_ID" >/dev/null
    VM_MODEL=$(az_read vm show --resource-group "$RG" --name "$VM")
    owned <<<"$VM_MODEL" || die 'VM ownership could not be verified.'
    DISK_ID=$(jq -r '.storageProfile.osDisk.managedDisk.id' <<<"$VM_MODEL")
    [[ ${DISK_ID,,} == "/subscriptions/${SUBSCRIPTION,,}/resourcegroups/${RG,,}/providers/microsoft.compute/disks/${DISK,,}" ]] ||
        die 'Unexpected OS disk identity; refusing to tag it for cleanup.'
    disk_model=$(az_read disk show --ids "$DISK_ID")
    [[ $(jq -r '.creationData.createOption' <<<"$disk_model") == FromImage ]] ||
        die 'Unexpected disk provenance; refusing to tag it for cleanup.'
    az_write tag update --resource-id "$DISK_ID" --operation Merge --tags "vpnProvisionRun=$RUN_ID" >/dev/null
    az_write vm auto-shutdown --resource-group "$RG" --name "$VM" --off >/dev/null
}

verify_deployment() {
    local disk ip nsg nic subnet schedules schedule details resources
    VM_MODEL=$(az_read vm show --resource-group "$RG" --name "$VM")
    jq -e --arg key "$SSH_KEY" --arg image "$IMAGE" --arg size "$SIZE" --arg admin "$ADMIN" \
        --argjson gb "$DISK_GB" '
        (.storageProfile.imageReference | [.publisher,.offer,.sku,.version] | join(":")) == $image
        and .hardwareProfile.vmSize == $size
        and .osProfile.adminUsername == $admin
        and .osProfile.linuxConfiguration.disablePasswordAuthentication == true
        and ([.osProfile.linuxConfiguration.ssh.publicKeys[].keyData | rtrimstr("\n")] == [$key])
        and .storageProfile.osDisk.managedDisk.storageAccountType == "StandardSSD_LRS"
        and .storageProfile.osDisk.diskSizeGb == $gb
        and (.storageProfile.dataDisks | length) == 0
        and (.priority // "Regular") == "Regular"
        and .availabilitySet == null and ((.zones // []) | length) == 0
        and .provisioningState == "Succeeded"
    ' <<<"$VM_MODEL" >/dev/null || die 'VM read-back does not match the approved settings.'
    disk=$(az_read disk show --ids "$DISK_ID")
    jq -e --argjson gb "$DISK_GB" '.sku.name == "StandardSSD_LRS" and .diskSizeGb == $gb and .osType == "Linux"' \
        <<<"$disk" >/dev/null || die 'Disk read-back does not match the approved settings.'
    ip=$(az_read network public-ip show --resource-group "$RG" --name "$PIP")
    jq -e '.sku.name == "Standard" and .publicIPAllocationMethod == "Static"
        and .publicIPAddressVersion == "IPv4" and (.ipAddress|type) == "string" and (.ipAddress|length) > 0' \
        <<<"$ip" >/dev/null || die 'Public IP read-back does not match the approved settings.'
    PUBLIC_IP=$(jq -r .ipAddress <<<"$ip")
    say "Public-IP platform zones: $(jq -c '.zones // []' <<<"$ip") (no optional HA was requested)."
    nsg=$(az_read network nsg show --resource-group "$RG" --name "$NSG")
    jq -e --arg protocol "$PROTOCOL" --arg port "$VPN_PORT" '
        def matches($name; $protocol; $port; $priority):
            .name == $name and .protocol == $protocol and .destinationPortRange == $port
            and .priority == $priority and .access == "Allow" and .direction == "Inbound"
            and .sourceAddressPrefix == "0.0.0.0/0" and .sourcePortRange == "*"
            and .destinationAddressPrefix == "*";
        (.securityRules | length) == 2
        and any(.securityRules[]; matches("AllowSSH"; "Tcp"; "22"; 100))
        and any(.securityRules[]; matches("AllowVPN"; $protocol; $port; 110))
    ' <<<"$nsg" >/dev/null || die 'NSG rules differ from the approved SSH/VPN rules.'
    nic=$(az_read network nic show --resource-group "$RG" --name "$NIC")
    jq -e --arg nsg "$(jq -r .id <<<"$nsg")" --arg ip "$(jq -r .id <<<"$ip")" '
        .networkSecurityGroup.id == $nsg and (.ipConfigurations|length) == 1
        and .ipConfigurations[0].privateIPAddressVersion == "IPv4"
        and .ipConfigurations[0].publicIPAddress.id == $ip
    ' <<<"$nic" >/dev/null || die 'NIC does not reference the approved NSG/public IP.'
    subnet=$(az_read network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name "$SUBNET")
    jq -e --arg cidr "$SUBNET_CIDR" '.addressPrefix == $cidr and .defaultOutboundAccess == false' \
        <<<"$subnet" >/dev/null || die 'Subnet differs from the approved private-outbound configuration.'
    schedules=$(az_read resource list --resource-group "$RG" --resource-type Microsoft.DevTestLab/schedules)
    while IFS= read -r schedule; do
        details=$(az_read resource show --ids "$schedule")
        if [[ $(jq -r '.properties.targetResourceId // "" | ascii_downcase' <<<"$details") == "$(jq -r '.id|ascii_downcase' <<<"$VM_MODEL")" ]]; then
            jq -e '.properties.status == "Disabled"' <<<"$details" >/dev/null ||
                die 'A VM auto-shutdown schedule is still enabled.'
        fi
    done < <(jq -r '.[].id' <<<"$schedules")
    resources=$(inventory)
    if jq -e 'any(.[]; (.type|ascii_downcase) |
        test("recoveryservices|dataprotection|snapshots|loadbalancers|natgateways|bastionhosts|operationalinsights|availabilitysets"))' \
        <<<"$resources" >/dev/null; then
        say 'WARNING: unexpected backup/HA/monitoring resources exist, possibly created by Azure Policy:'
        jq -r '.[] | "\(.type) \(.id)"' <<<"$resources" >&2
        die 'Unexpected resource extras detected; review policy-created resources before treating this deployment as cost-minimal.'
    fi
}

workflow() {
    choose_subscription
    collect_inputs
    say 'Discovering official Debian 12 images and eligible VM sizes...'
    discover_images
    discover_sizes
    choose_size
    deployment_summary
    if ! confirm 'Create this deployment?'; then say 'Cancelled. No resources created.'; return 0; fi
    create_infrastructure
    verify_deployment
    COMPLETED=true
    printf '\nInfrastructure ready. VPN software is NOT installed.\nPublic IPv4: %s\nSSH: ssh %s@%s\nVPN preset: %s (%s %s)\nResource group: %s\n' \
        "$PUBLIC_IP" "$ADMIN" "$PUBLIC_IP" "$VPN" "$PROTOCOL" "$VPN_PORT" "$RG"
    say 'Azure configuration was read back. Guest SSH, Debian runtime and VPN connectivity were not tested.'
}

main() {
    [[ $# == 0 ]] || die 'This script accepts no parameters; run it interactively.'
    [[ -t 0 && -t 1 ]] || die 'An interactive terminal is required; no unattended mode is supported.'
    local tool
    for tool in az jq curl mktemp grep od tr; do command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"; done
    WORK_DIR=$(mktemp -d)
    trap 'rm -f -- "$WORK_DIR"/{az-error,images.json,skus.json,usage.json,eligible.json,prices.ndjson,price-page.json,prices.json,shortlist.json}; rmdir -- "$WORK_DIR"' EXIT
    RUN_ID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [[ $RUN_ID =~ ^[a-f0-9]{32}$ ]] || die 'Unable to generate a unique ownership marker.'
    trap 'handle_failure "$?" "$LINENO"' ERR
    trap 'handle_failure 130 "$LINENO"' INT
    trap 'handle_failure 143 "$LINENO"' TERM
    workflow
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
