#!/usr/bin/env bash

set -Eeuo pipefail

# Grafana correlations are the only cross-signal link in this stack that cannot
# be expressed declaratively: GrafanaDatasource.spec.datasource has no
# `correlations` field (that key exists only in Grafana's own file-based
# datasource provisioning, which the operator does not use). The other five
# links live in Grafana/kubernetes/{loki,tempo}-datasource.yaml.
#
# These two cover the metrics-side directions. They exist as correlations rather
# than exemplars because VictoriaMetrics does not store exemplars, so the usual
# exemplarTraceIdDestinations route from a Prometheus datasource is unavailable.
# Unlike Loki derived fields, a correlation can read several labels off the
# source row, so both of these scope by service *and* namespace.
#
# The script is idempotent: correlations matching a label are deleted first.

readonly NAMESPACE="${NAMESPACE:-monitoring}"
readonly GRAFANA_SERVICE="${GRAFANA_SERVICE:-grafana-service}"
readonly GRAFANA_USER="${GRAFANA_USER:-admin}"
readonly GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
readonly LOCAL_PORT="${LOCAL_PORT:-13000}"
readonly SOURCE_UID="VictoriaMetrics"
readonly DATASOURCE_WAIT_RETRIES="${DATASOURCE_WAIT_RETRIES:-120}"
readonly DATASOURCE_RETRY_DELAY="${DATASOURCE_RETRY_DELAY:-2}"

readonly TRACES_LABEL="View traces for this service"
readonly LOGS_LABEL="View logs for this service"

port_forward_pid=""

cleanup() {
    if [[ -n "${port_forward_pid}" ]]; then
        kill "${port_forward_pid}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

api() {
    local method="$1" path="$2"
    shift 2

    curl -sS --fail-with-body -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
        -X "${method}" "http://localhost:${LOCAL_PORT}${path}" \
        -H 'Content-Type: application/json' "$@"
}

# The correlations API validates the source and target datasource UIDs and 404s
# if either is missing. grafana-operator pushes GrafanaDatasource CRs into the
# instance on its own reconcile loop, which finishes some time after the Grafana
# deployment reports rolled out, so a healthy /api/health is not enough.
#
# The budget has to cover a full operator resync: a CR created before the
# Grafana instance existed (which is the case for every datasource the
# VictoriaMetrics chart ships) is parked with NoMatchingInstances and only
# retried on the next periodic pass. That interval is defaultResyncPeriod in
# Grafana/helm/values.yaml; keep this comfortably above it.
wait_for_datasource() {
    local uid="$1"

    for _ in $(seq 1 "${DATASOURCE_WAIT_RETRIES}"); do
        if api GET "/api/datasources/uid/${uid}" >/dev/null 2>&1; then
            return 0
        fi
        sleep "${DATASOURCE_RETRY_DELAY}"
    done

    printf 'Datasource %s was never registered in Grafana after %ss\n' \
        "${uid}" "$((DATASOURCE_WAIT_RETRIES * DATASOURCE_RETRY_DELAY))" >&2
    printf 'grafana-operator state (NO MATCHING INSTANCES means the CR never reached Grafana):\n' >&2
    kubectl -n "${NAMESPACE}" get grafanadatasources >&2 || true
    exit 1
}

# Grafana has no upsert for correlations, so drop any previous run's copies.
delete_existing() {
    local label="$1" uid

    while read -r uid; do
        [[ -z "${uid}" ]] && continue
        printf '  removing existing correlation %s\n' "${uid}"
        api DELETE "/api/datasources/uid/${SOURCE_UID}/correlations/${uid}" >/dev/null
    done < <(
        api GET "/api/datasources/correlations" |
            python3 -c "
import json, sys
for c in json.load(sys.stdin).get('correlations', []):
    if c.get('sourceUID') == '${SOURCE_UID}' and c.get('label') == '''${label}''':
        print(c['uid'])
"
    )
}

require_command kubectl
require_command curl
require_command python3

kubectl -n "${NAMESPACE}" port-forward "svc/${GRAFANA_SERVICE}" "${LOCAL_PORT}:3000" >/dev/null 2>&1 &
port_forward_pid=$!

# Wait for the tunnel rather than sleeping a fixed amount.
for _ in $(seq 1 30); do
    if curl -sf "http://localhost:${LOCAL_PORT}/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

for datasource_uid in "${SOURCE_UID}" tempo loki; do
    printf 'Waiting for datasource %s\n' "${datasource_uid}"
    wait_for_datasource "${datasource_uid}"
done

printf 'Applying metrics -> traces correlation\n'
delete_existing "${TRACES_LABEL}"
# ${service} and ${namespace} are read off the source row, so this fires on any
# VictoriaMetrics panel carrying both labels: span metrics (where the generator
# emits `service`, and write_relabel_configs in Tempo/helm/values.yaml renames
# its `service_namespace` to `namespace`) and scraped app metrics (where the
# operator stamps both by default). In Tempo the same two values are the
# service.name and service.namespace resource attributes.
api POST "/api/datasources/uid/${SOURCE_UID}/correlations" -d @- >/dev/null <<JSON
{
  "targetUID": "tempo",
  "label": "${TRACES_LABEL}",
  "description": "Jump from a span metric series to the traces that produced it",
  "type": "query",
  "config": {
    "type": "query",
    "field": "Value",
    "target": {
      "queryType": "traceql",
      "query": "{resource.service.name=\"\${service}\" && resource.service.namespace=\"\${namespace}\"}"
    }
  }
}
JSON

printf 'Applying metrics -> logs correlation\n'
delete_existing "${LOGS_LABEL}"
# Loki calls the service `service_name` where metrics call it `service`, so the
# selector translates. Alloy sets both labels from pod metadata
# (app.kubernetes.io/name and the Kubernetes namespace). Renaming the Loki side
# to `service` would backfire: discover_service_name would then synthesise a
# second service_name label from it and double the stream cardinality.
api POST "/api/datasources/uid/${SOURCE_UID}/correlations" -d @- >/dev/null <<JSON
{
  "targetUID": "loki",
  "label": "${LOGS_LABEL}",
  "description": "Jump from a metric series to that service's logs",
  "type": "query",
  "config": {
    "type": "query",
    "field": "Value",
    "target": {
      "expr": "{service_name=\"\${service}\", namespace=\"\${namespace}\"}"
    }
  }
}
JSON

printf 'Done.\n'
