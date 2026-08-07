#!/usr/bin/env bash

set -Eeuo pipefail

# Assign first, mark readonly second: `readonly VAR="$(...)"` reports the exit
# status of the readonly builtin, so set -e would not see a failing subshell.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT
MAKE_BIN="${MAKE:-make}"
readonly MAKE_BIN

current_target="startup checks"

trap 'printf "\nStartup failed during: %s\n" "${current_target}" >&2' ERR

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

require_environment() {
    local variable_name

    for variable_name in SMTP_USERNAME SMTP_PASSWORD SLACK_WEBHOOK_URL GMAIL_PASSWORD; do
        if [[ -z "${!variable_name:-}" ]]; then
            printf 'Required environment variable is not set: %s\n' "$variable_name" >&2
            exit 1
        fi
    done
}

run_target() {
    # Deliberately global: the ERR trap reads it to name the failing target.
    current_target="$1"

    printf '\n==> %s\n' "${current_target}"
    "${MAKE_BIN}" --no-print-directory -C "${PROJECT_ROOT}" "${current_target}"
}

for command_name in "${MAKE_BIN}" kind docker kubectl helm wget base64; do
    require_command "${command_name}"
done
require_environment

# Infrastructure needed by every component.
run_target create-cluster
run_target wait-cluster
run_target provision-alloy-data-dirs
run_target configure-etcd-metrics
run_target wait-etcd-metrics
run_target create-namespaces
run_target deploy-local-path-provisioner
run_target wait-local-path-provisioner

# Operators and CRDs must exist before their custom resources are applied.
run_target install-grafana-operator
run_target install-cnpg
run_target wait-cnpg

# Grafana's only real dependency is its own Postgres database - nothing here
# needs VictoriaMetrics, Loki or Tempo to exist yet. Bringing Grafana up before
# VictoriaMetrics matters because the VictoriaMetrics chart also creates
# GrafanaDatasource CRs (defaultDatasources.grafanaOperator.enabled). Those CRs
# reconcile through grafana-operator's error-backoff queue, not a resync timer:
# a CR whose Grafana instance doesn't exist yet fails with "no matching
# instances", and controller-runtime requeues failed reconciles with a delay
# that doubles from 5ms up to a 1000s cap. Installing VictoriaMetrics first (as
# this used to) meant its datasource CRs accumulated ~10 minutes of failed,
# backing-off retries before Grafana existed at all - by the time it did, the
# next retry could be minutes away. With Grafana ready first, that first
# reconcile attempt just succeeds.
run_target deploy-postgres
run_target wait-postgres
run_target create-grafana-smtp-secret
run_target create-grafana-slack-secret
run_target deploy-grafana
run_target wait-grafana

# VictoriaMetrics must still come before anything that depends on its CRDs:
# Loki and Tempo's ServiceMonitor/PrometheusRule (converted by the VM
# operator), and the two Node app VMServiceScrapes below.
run_target add-victoria-metrics-helm-repo
# install-victoria-metrics refuses to run without this secret.
run_target create-alertmanager-smtp-secret
run_target install-victoria-metrics

# Correlations only need the VictoriaMetrics/tempo/loki datasource UIDs to be
# registered in Grafana, not for those services to actually be running yet -
# run it here to fail fast rather than after SeaweedFS/Loki/Tempo/Alloy.
run_target apply-metrics-to-logs-and-traces-correlation

run_target create-seaweedfs-secret
run_target deploy-seaweedfs
run_target wait-seaweedfs

# Loki needs SeaweedFS and the VictoriaMetrics-provided ServiceMonitor CRD;
# its Helm --wait verifies all chart workloads.
run_target add-loki-helm-repo
run_target install-loki

# Tempo 3 needs its Kafka-compatible write buffer, SeaweedFS object storage,
# and the same ServiceMonitor/PrometheusRule CRDs as Loki.
run_target deploy-tempo
run_target wait-tempo

# Grafana Alloy
run_target add-grafana-alloy-helm-repo
run_target deploy-grafana-alloy-logs

# The app manifest contains a VMServiceScrape, so VictoriaMetrics goes first.
# run_target deploy-shoehub-app
# run_target wait-shoehub-app

run_target deploy-nodejs-app-1
run_target deploy-nodejs-app-2
run_target wait-nodejs-app-1
run_target wait-nodejs-app-2

printf '\nAll components are ready.\n'
