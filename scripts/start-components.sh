#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly MAKE_BIN="${MAKE:-make}"

trap 'printf "\nStartup failed at line %s.\n" "$LINENO" >&2' ERR

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

require_environment() {
    local variable_name

    for variable_name in SMTP_USERNAME SMTP_PASSWORD SLACK_WEBHOOK_URL; do
        if [[ -z "${!variable_name:-}" ]]; then
            printf 'Required environment variable is not set: %s\n' "$variable_name" >&2
            exit 1
        fi
    done
}

run_target() {
    local target="$1"

    printf '\n==> %s\n' "$target"
    "${MAKE_BIN}" --no-print-directory -C "${PROJECT_ROOT}" "${target}"
}

for command_name in make minikube kubectl helm; do
    require_command "${command_name}"
done
require_environment

# Infrastructure needed by every component.
run_target start-cluster
run_target wait-cluster
run_target configure-etcd-metrics
run_target wait-etcd-metrics
run_target create-namespaces
run_target deploy-local-path-provisioner
run_target wait-local-path-provisioner

# Operators and CRDs must exist before their custom resources are applied.
run_target install-grafana-operator
run_target install-cnpg
run_target wait-cnpg
run_target add-victoria-metrics-helm-repo
run_target install-victoria-metrics

# Backing stores must be ready before Loki and Grafana start.
run_target deploy-postgres
run_target wait-postgres
run_target create-seaweedfs-secret
run_target deploy-seaweedfs
run_target wait-seaweedfs

# Loki needs SeaweedFS; its Helm --wait verifies all chart workloads.
run_target add-loki-helm-repo
run_target install-loki

# The app manifest contains a VMServiceScrape, so VictoriaMetrics goes first.
run_target deploy-shoehub-app
run_target wait-shoehub-app

# Grafana consumes PostgreSQL, VictoriaMetrics, and Loki.
run_target create-grafana-smtp-secret
run_target create-grafana-slack-secret
run_target deploy-grafana
run_target wait-grafana

printf '\nAll components are ready.\n'
