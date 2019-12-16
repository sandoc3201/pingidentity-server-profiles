#!/usr/bin/env sh
#
# Ping Identity DevOps - Docker Build Hooks
#
#- This hook runs after the PingDirectory service has been started and is running.  It
#- will determine if it is part of a directory replication topology by the presence
#- of a TOPOLOGY_SERVICE_BAME .  If not present, then replication will not be enabled.  
#- Otherwise,
#- it will perform the following steps regarding replication.
#-
${VERBOSE} && set -x

# shellcheck source=../../pingcommon/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

# shellcheck source=/dev/null
test -f "${STAGING_DIR}/env_vars" && . "${STAGING_DIR}/env_vars"
# shellcheck source=pingdirectory.lib.sh
test -f "${HOOKS_DIR}/pingdirectory.lib.sh" && . "${HOOKS_DIR}/pingdirectory.lib.sh"

_tmpPodPort="${_podLdapPort}"
test "${LDAP_SECURITY}" == "ssl" && _tmpPort="${_podLdapsPort}"
echo "Running ldapsearch test on this Server (${_podInstanceName})"
echo "        ${_podHostname}:${_tmpPodPort}"
waitUntilLdapUp "${_podHostname}" "${_tmpPodPort}" ""

echo "
Updating the Server Instance hostname/ldaps-port:
         instance: ${_podInstanceName}
         hostname: ${_podHostname}
        ldap-port: ${_podLdapPort}
       ldaps-port: ${_podLdapsPort}"

dsconfig set-server-instance-prop --no-prompt --quiet \
    --instance-name "${_podInstanceName}" \
    --set hostname:${_podHostname} \
    --set ldap-port:${_podLdapPort} \
    --set ldaps-port:${_podLdapsPort}

_updateServerInstanceResult=$?
echo "Updating the Server Instance ${_podInstanceName} result=${_updateServerInstanceResult}"

#
# If we are in GENESIS State, then, no replication will be setup
#
if test "${PD_STATE}" == "GENESIS" ; then
    echo "PD_STATE is GENESIS ==> Replication on this server won't be setup until more instances are added"
    exit 0
fi

if test "${_podInstanceName}" == "${_seedInstanceName}"; then
    echo ""
    echo "We are the SEED Server: ${_seedInstanceName} --> No need to enable replication"
    echo "TODO: We need to check for other servers"
    exit 0
fi

echo "Running dsreplication enable"

_tmpPort="${_seedLdapPort}"
test "${LDAP_SECURITY}" == "ssl" && _tmpPort="${_seedLdapsPort}"

echo "Running ldapsearch test on SEED Server (${_seedInstanceName})"
echo "        ${_seedHostname}:${_tmpPort}"
waitUntilLdapUp "${_seedHostname}" "${_tmpPort}" ""

_masterTopologyInstance=$(ldapsearch --host "${_seedHostname}" --port "${_tmpPort}" --terse --outputFormat json -b "cn=Mirrored subtree manager for base DN cn_Topology_cn_config,cn=monitor" -s base objectclass=* master-instance-name | jq -r .attributes[].values[])

printf "
#############################################
# Enabling Replication
#
# Current Master Topology Instance: ${_masterTopologyInstance}
#
#   %60s        %-60s
#   %60s  <-->  %-60s
#############################################
" "SEED Server" "POD Server" "${_seedHostname}:${_seedReplicationPort}" "${_podHostname}:${_podReplicationPort}"

_conn1="--port1 ${_seedLdapPort} --startTLS1"
_conn2="--port2 ${_seedLdapPort} --startTLS2"
test "${LDAP_SECURITY}" == "ssl" && _conn1="--port1 ${_seedLdapsPort} --useSSL1"
test "${LDAP_SECURITY}" == "ssl" && _conn2="--port2 ${_seedLdapsPort} --useSSL2"

dsreplication enable \
      --retryTimeoutSeconds ${RETRY_TIMEOUT_SECONDS} \
      --trustAll \
      --host1 "${_seedHostname}" \
      ${conn1} \
      --replicationPort1 "${_seedReplicationPort}" \
      --bindDN1 "${ROOT_USER_DN}" --bindPasswordFile1 "${ROOT_USER_PASSWORD_FILE}" \
      \
      --host2 "${_podHostname}" \
      ${conn2} \
      --replicationPort2 "${_podReplicationPort}" \
      --bindDN2 "${ROOT_USER_DN}" --bindPasswordFile2 "${ROOT_USER_PASSWORD_FILE}" \
      \
      --adminUID "${ADMIN_USER_NAME}" --adminPasswordFile "${ADMIN_USER_PASSWORD_FILE}" \
      --no-prompt --ignoreWarnings \
      --baseDN "${USER_BASE_DN}" \
      --noSchemaReplication \
      --enableDebug --globalDebugLevel verbose

_replEnableResult=$?
echo "Replication enable for POD Server result=${_replEnableResult}"

if test ${_replEnableResult} -ne 0; then
    echo "Not running dsreplication initialize since enable failed with a non-successful return code"
    exit ${_replEnableResult}
fi

echo "Getting Topology from SEED Server"
rm -rf "${TOPOLOGY_FILE}"
manage-topology export \
    --hostname "${_seedHostname}" \
    --port "${_tmpPort}" \
    --exportFilePath "${TOPOLOGY_FILE}"

cat "${TOPOLOGY_FILE}"

_destConn="--portDestination ${_seedLdapPort} --startTLSDestination"
test "${LDAP_SECURITY}" == "ssl" && _destConn="--portDestination ${_seedLdapsPort} --useSSLDestination"

echo "Initializing replication on POD Server"
dsreplication initialize \
      --retryTimeoutSeconds ${RETRY_TIMEOUT_SECONDS} \
      --trustAll \
      \
      --topologyFilePath "${TOPOLOGY_FILE}" \
      \
      --hostDestination "${_podHostname}" ${_destConn} \
      \
      --baseDN "${USER_BASE_DN}" \
      --adminUID "${ADMIN_USER_NAME}" \
      --adminPasswordFile "${ADMIN_USER_PASSWORD_FILE}" \
      --no-prompt \
      --enableDebug \
      --globalDebugLevel verbose

_replInitResult=$?
echo "Replication initialize result=${_replInitResult}"

# test ${_replInitResult} -eq 0 && touch "${REPL_SETUP_MARKER_FILE}"
exit ${_replInitResult}

