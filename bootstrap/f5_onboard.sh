#!/bin/bash -x

# NOTE: Startup Script is run once / initialization only (Cloud-Init behavior vs. typical re-entrant for Azure Custom Script Extension )
# For 15.1+ and above, Cloud-Init will run the script directly and can remove Azure Custom Script Extension

mkdir -p  /var/log/cloud /config/cloud /var/config/rest/downloads

mkdir -p /config/cloud

LOG_FILE=/var/log/cloud/startup-script.log
[[ ! -f $LOG_FILE ]] && touch $LOG_FILE || { echo "Run Only Once. Exiting"; exit; }
npipe=/tmp/$$.tmp
trap "rm -f $npipe" EXIT
mknod $npipe p
tee <$npipe -a $LOG_FILE /dev/ttyS0 &
exec 1>&-
exec 1>$npipe
exec 2>&1

# Run Immediately Before MCPD
/usr/bin/setdb provision.extramb 1000
/usr/bin/setdb restjavad.useextramb true

curl -o /config/cloud/do_w_admin.json -s --fail --retry 60 -m 10 -L https://raw.githubusercontent.com/6a6d/terraform-azure-bip-deployment/main/config/onboard_do.json


### write_files:
# Download or Render BIG-IP Runtime Init Config

cat << 'EOF' > /config/cloud/runtime-init-conf.yaml
---
controls:
  extensionInstallDelayInMs: 60000
runtime_parameters:
  - name: USER_NAME
    type: static
    value: ${bigip_username}
  - name: HOST_NAME
    type: metadata
    metadataProvider:
      environment: azure
      type: compute
      field: name
  - name: SSH_KEYS
    type: static
    value: "${ssh_keypair}"
EOF

if ${az_keyvault_authentication}
then
  cat << 'EOF' >> /config/cloud/runtime-init-conf.yaml
  - name: ADMIN_PASS
    type: secret
    secretProvider:
      environment: azure
      type: KeyVault
      vaultUrl: ${vault_url}
      secretId: ${secret_id}
pre_onboard_enabled: []
EOF
else

  cat << 'EOF' >> /config/cloud/runtime-init-conf.yaml
  - name: ADMIN_PASS
    type: static
    value: ${bigip_password}
pre_onboard_enabled: []
EOF
fi

cat /config/cloud/runtime-init-conf.yaml > /config/cloud/runtime-init-conf-backup.yaml

cat << 'EOF' >> /config/cloud/runtime-init-conf.yaml
extension_packages:
  install_operations:
    - extensionType: do
      extensionVersion: ${DO_VER}
      extensionUrl: ${DO_URL}
    - extensionType: as3
      extensionVersion: ${AS3_VER}
      extensionUrl: ${AS3_URL}
    - extensionType: ts
      extensionVersion: ${TS_VER}
      extensionUrl: ${TS_URL}
    - extensionType: cf
      extensionVersion: ${CFE_VER}
      extensionUrl: ${CFE_URL}
    - extensionType: fast
      extensionVersion: ${FAST_VER}
      extensionUrl: ${FAST_URL}
extension_services:
  service_operations:
    - extensionType: do
      type: inline
      value:
        schemaVersion: 1.0.0
        class: Device
        async: true
        Common:
          class: Tenant
          hostname: '{{{HOST_NAME}}}.com'
          myNtp:
            class: NTP
            servers:
              - 0.pool.ntp.org
            timezone: UTC
          myDns:
            class: DNS
            nameServers:
              - 168.63.129.16
          admin:
            class: User
            partitionAccess:
              all-partitions:
                role: admin
            password: '{{{ADMIN_PASS}}}'
            shell: bash
            keys:
              - '{{{SSH_KEYS}}}'
            userType: regular
          '{{{USER_NAME}}}':
            class: User
            partitionAccess:
              all-partitions:
                role: admin
            password: '{{{ADMIN_PASS}}}'
            shell: bash
            keys:
              - '{{{SSH_KEYS}}}'
            userType: regular
post_onboard_enabled: []
EOF

cat << 'EOF' >> /config/cloud/runtime-init-conf-backup.yaml
extension_services:
  service_operations:
    - extensionType: do
      type: inline
      value:
        schemaVersion: 1.0.0
        class: Device
        async: true
        Common:
          class: Tenant
          hostname: '{{{HOST_NAME}}}.com'
          myNtp:
            class: NTP
            servers:
              - 0.pool.ntp.org
            timezone: UTC
          myDns:
            class: DNS
            nameServers:
              - 168.63.129.16
          admin:
            class: User
            partitionAccess:
              all-partitions:
                role: admin
            password: '{{{ADMIN_PASS}}}'
            shell: bash
            keys:
              - '{{{SSH_KEYS}}}'
            userType: regular
          '{{{USER_NAME}}}':
            class: User
            partitionAccess:
              all-partitions:
                role: admin
            password: '{{{ADMIN_PASS}}}'
            shell: bash
            keys:
              - '{{{SSH_KEYS}}}'
            userType: regular
post_onboard_enabled: []
EOF

for i in {1..30}; do
    curl -fv --retry 1 --connect-timeout 5 -L ${INIT_URL} -o "/var/config/rest/downloads/f5-bigip-runtime-init.gz.run" && break || sleep 10
done
# Install
bash /var/config/rest/downloads/f5-bigip-runtime-init.gz.run -- '--cloud azure'
# Run
f5-bigip-runtime-init --config-file /config/cloud/runtime-init-conf.yaml
sleep 5
f5-bigip-runtime-init --config-file /config/cloud/runtime-init-conf-backup.yaml
