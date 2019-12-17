#!/usr/bin/env sh
#
# Ping Identity DevOps - Docker Build Hooks
#
#- This scrip is called to check if there is an existing server
#- and if so, it will return a 1, else 0
#

# shellcheck source=../../pingcommon/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

${VERBOSE} && set -x

rm -rf "${STATE_PROPERTIES}"

RUN_PLAN="UNKNOWN"
PD_STATE="UNKNOWN"
SERVER_UUID_FILE="${SERVER_ROOT_DIR}/config/server.uuid"
ORCHESTRATION_TYPE=$(echo "${ORCHESTRATION_TYPE}" | tr '[:lower:]' '[:upper:]')

_planFile="/tmp/plan-${ORCHESTRATION_TYPE}.txt"
rm -rf "${_planFile}"

if  test -f "${SERVER_UUID_FILE}" ; then
    . "${SERVER_UUID_FILE}"

    RUN_PLAN="RESTART"
    PD_STATE="UPDATE"
else
    RUN_PLAN="START"
    PD_STATE="SETUP"

    if test -d "${SERVER_ROOT_DIR}" ; then
        echo "No server.uuid found. Removing existing SERVER_ROOT_DIR '${SERVER_ROOT_DIR}''"
        rm -rf "${SERVER_ROOT_DIR}"
    fi
fi

#
# Create all the POD Server details
#
_podName=$(hostname)
_ordinal=$(echo ${_podName##*-})

_podHostname="$(hostname)"
_podLdapsPort="${LDAPS_PORT}"
_podReplicationPort="${REPLICATION_PORT}"

echo "###################################################################################
#            ORCHESTRATION_TYPE: ${ORCHESTRATION_TYPE}
#                      HOSTNAME: ${HOSTNAME}
#                    serverUUID: ${serverUUID}
#" >> "${_planFile}"

# if running in kubernetes
if test "${ORCHESTRATION_TYPE}" = "KUBERNETES" ; then

    if test -z "${K8S_STATEFUL_SET_NAME}"; then
        container_failure "03" "KUBERNETES Orchestation ==> K8S_STATEFUL_SET_NAME required"
    fi
    #
    # Check to see if we have the variables for single or multi cluster replication
    #
    # If we have both K8S_CLUSTER and K8S_SEED_CLUSTER defined then we are in a 
    # multi cluster mode.
    #
    if test -z "${K8S_CLUSTER}" ||
    test -z "${K8S_SEED_CLUSTER}"; then
        _clusterMode="single"
        echo "Single Mode"
    else
        _clusterMode="multi"
        echo "Multi Mode"

        if test -z "${K8S_INSTANCE_NAME_PREFIX}"; then
            echo "K8S_INSTANCE_NAME_PREFIX not set.  Defaulting to K8S_STATEFUL_SET_NAME- (${K8S_STATEFUL_SET_NAME}-)"
            K8S_INSTANCE_NAME_PREFIX="${K8S_STATEFUL_SET_NAME}-"
        fi

        if test -z "${K8S_INSTANCE_NAME_SUFFIX}"; then
            echo "K8S_INSTANCE_NAME_SUFFIX not set.  Defaulting to K8S_CLUSTER (${K8S_CLUSTER})"
            K8S_INSTANCE_NAME_SUFFIX="${K8S_CLUSTER}-"
        fi

        if test ${K8S_INCREMENT_PORTS} == true; then
            echo "K8S_INCREMENT_PORTS is used ==> Using different ports for each instance, incremented from LDAPS_PORT (${LDAPS_PORT}) and REPLICATION_PORT (${REPLICATION_PORT})"
        else
            echo "K8S_INCREMENT_PORTS not used ==> Using same ports for all instancesLDAPS_PORT (${LDAPS_PORT}) and REPLICATION_PORT (${REPLICATION_PORT})"
        fi
    fi

    _seedHostname="${K8S_STATEFUL_SET_NAME}-0"
    _seedLdapsPort="${LDAPS_PORT}"
    _seedReplicationPort="${REPLICATION_PORT}"

    #
    # Multi Cluster Details
    if test "${_clusterMode}" == "multi"; then
        _podHostname="${K8S_INSTANCE_NAME_PREFIX}${_ordinal}${K8S_INSTANCE_NAME_SUFFIX}"
        _seedHostname="${K8S_INSTANCE_NAME_PREFIX}0${K8S_INSTANCE_NAME_SUFFIX}"

        if test "${K8S_INCREMENT_PORTS}" == "true"; then
            _podLdapsPort=$(( LDAPS_PORT + _ordinal ))
            LDAPS_PORT=${_podLdapsPort}
            _podReplicationPort=$(( REPLICATION_PORT + _ordinal ))
            REPLICATION_PORT=${_podReplicationPort}
        fi
    fi

    _podInstanceName="${_podHostname}"
    _seedInstanceName="${_seedHostname}"

    if test "${_podInstanceName}" = "${_seedInstanceName}" ; then
        echo "We are the SEED server (${_seedInstanceName})"

        if test -z "${serverUUID}" ; then
            #
            # First, we will check to see if there are any servers available in
            # existing cluster
            nslookup ${K8S_STATEFUL_SET_SERVICE_NAME}  2>/dev/null | awk '$0 ~ /^Address / {print $4}' >/tmp/_serviceHosts
            _numHosts=$( grep -v "$(hostname -f)" /tmp/_serviceHosts | wc -l 2> /dev/null)

            cat /tmp/_serviceHosts
            # echo "Number of other services available = ${_numHosts}"

            if test ${_numHosts} -eq 0 ; then
                #
                # Second, we need to check other clusters
                if test "${_clusterMode}" == "multi"; then
                    echo_red "We need to check all 0 servers in each cluster"
                fi

                PD_STATE="GENESIS"
            fi
        fi
    fi

    echo "#         K8S_STATEFUL_SET_NAME: ${K8S_STATEFUL_SET_NAME}
# K8S_STATEFUL_SET_SERVICE_NAME: ${K8S_STATEFUL_SET_SERVICE_NAME}
#
#                   K8S_CLUSTER: ${K8S_CLUSTER}
#              K8S_SEED_CLUSTER: ${K8S_SEED_CLUSTER}
#      K8S_INSTANCE_NAME_PREFIX: ${K8S_INSTANCE_NAME_PREFIX}
#      K8S_INSTANCE_NAME_SUFFIX: ${K8S_INSTANCE_NAME_SUFFIX}
#           K8S_INCREMENT_PORTS: ${K8S_INCREMENT_PORTS}
#
#" >> "${_planFile}"


    case "${PD_STATE}" in
        GENESIS)
            echo "#     Startup Plan
#        - manage-profile setup
#        - import data" >> "${_planFile}"

            echo "
##################################################################################
#
#                                   IMPORTANT MESSAGE
#
#                                  GENESIS STATE FOUND
#
# Based on the following information, we have determined that we are the SEED server
# in the GENESIS state (First server to come up in this stateful set) due to the
# folloing conditions:
#
#   1. We couldn't find a valid server.uuid file
#   2. Our host name ($(hostname))is the 1st one in the stateful set (${K8S_STATEFUL_SET_SERVICE_NAME}-0)
#   3. There are no other servers currently running in the stateful set (${K8S_STATEFUL_SET_SERVICE_NAME})
#
# If it is suspected that we shoudn't be in the GENESIS state, take actions to
# remediate.
#
##################################################################################
"
            ;;
        SETUP)
            echo "#     Startup Plan
#        - manage-profile setup
#        - repl enable (from SEED Server-${_seedInstanceName})
#        - repl init   (from topology.json, from SEED Server-${_seedInstanceName})" >> "${_planFile}"
            ;;
        UPDATE)
            echo "#     Startup Plan
#        - manage-profile update
#        - repl enable (from SEED Server-${_seedInstanceName})
#        - repl init   (from topology.json, from SEED Server-${_seedInstanceName})" >> "${_planFile}"
            ;;
        *)
            container_failure 08 "Unknown PD_STATE of ($PD_STATE)"
    esac
fi
if test "${ORCHESTRATION_TYPE}" = "COMPOSE" ; then
    # Assume GENESIS state for now, if we aren't kubernetes when setting up
    if test "${RUN_PLAN}" = "START" ; then
        PD_STATE="GENESIS"
        nslookup ${COMPOSE_SERVICE_NAME}_1 2>/dev/null | awk '$0 ~ /^Address / {print $4}' | grep ${HOSTNAME} || PD_STATE="SETUP"
    fi
fi

if test -z "${ORCHESTRATION_TYPE}" && test "${PD_STATE}" = "SETUP"; then
    PD_STATE="GENESIS"
fi

test "${RUN_PLAN}" = "RESTART" && PD_STATE="UPDATE"

echo "
###################################################################################
#  
#                      PD_STATE: ${PD_STATE}
#                      RUN_PLAN: ${RUN_PLAN}
#" >> "${STATE_PROPERTIES}"

cat "${_planFile}" >> "${STATE_PROPERTIES}"

echo "###################################################################################
#
# POD Server Information
#                 instance name: ${_podInstanceName}
#                      hostname: ${_podHostname}
#                    ldaps port: ${_podLdapsPort}
#              replication port: ${_podReplicationPort}
#
# SEED Server Information
#                 instance name: ${_seedInstanceName}
#                      hostname: ${_seedHostname}
#                    ldaps port: ${_seedLdapsPort}
#              replication port: ${_seedReplicationPort}
###################################################################################
" >> "${STATE_PROPERTIES}"

echo "
###
# PingDirectory orchestration, run plan and current state
###
ORCHESTRATION_TYPE=${ORCHESTRATION_TYPE}
RUN_PLAN=${RUN_PLAN}
PD_STATE=${PD_STATE}

###
# POD Server Info
###
_podInstanceName=${_podInstanceName}
_podHostname=${_podHostname}
_podLdapsPort=${_podLdapsPort}
_podReplicationPort=${_podReplicationPort}

###
# SEED Server Info
###
_seedInstanceName=${_seedInstanceName}
_seedHostname=${_seedHostname}
_seedLdapsPort=${_seedLdapsPort}
_seedReplicationPort=${_seedReplicationPort}
" >> "${STATE_PROPERTIES}"

echo "
LDAPS_PORT=${LDAPS_PORT}
REPLICATION_PORT=${REPLICATION_PORT}
" >> "${STAGING_DIR}/env_vars"

cat "${STATE_PROPERTIES}"