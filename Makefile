.PHONY: start-cluster stop-cluster
.PHONY: install-grafana-operator deploy-grafana list-grafana-versions
.PHONY: install-victoria-metrics list-victoria-metrics-versions
.PHONY: install-cnpg deploy-postgres list-postgres-versions

# General Variables
MONITORING_NAMESPACE := monitoring
DATABASE_NAMESPACE := database
PRODUCTION_NAMESPACE := production


# Grafana Variables
GRAFANA_HELM_CHART := oci://ghcr.io/grafana/helm-charts/grafana-operator
GRAFANA_HELM_REPO := $(subst oci://,,$(GRAFANA_HELM_CHART))
GRAFANA_HELM_CHART_VERSION := 5.24.0
GRAFANA_RELEASE_NAME := grafana-operator

# VictoriaMetrics Variables
VICTORIA_METRICS_HELM_REPO_NAME := vm
VICTORIA_METRICS_HELM_REPO_URL := https://victoriametrics.github.io/helm-charts/
VICTORIA_METRICS_HELM_CHART := vm/victoria-metrics-k8s-stack
VICTORIA_METRICS_HELM_CHART_VERSION := 0.85.6
VICTORIA_METRICS_RELEASE_NAME := vm

# CNPG Variables
CNPG_OPERATOR_URL := https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.1.yaml
CNPG_OPERATOR_NAMESPACE := cnpg-system

# Loki Variables
LOKI_HELM_CHART := grafana-community/loki
LOKI_HELM_CHART_VERSION := 18.4.4

# Cluster Commands
start-cluster:
	minikube start

stop-cluster:
	minikube stop

create-namespaces:
	kubectl create namespace ${MONITORING_NAMESPACE} || true
	kubectl create namespace ${CNPG_OPERATOR_NAMESPACE} || true
	kubectl create namespace ${DATABASE_NAMESPACE} || true
	kubectl create namespace ${PRODUCTION_NAMESPACE} || true


# Grafana Commands
list-grafana-versions:
	oras repo tags ${GRAFANA_HELM_REPO}

Grafana/helm/values.yaml:
	helm show values ${GRAFANA_HELM_CHART} \
	    --version ${GRAFANA_HELM_CHART_VERSION} > Grafana/helm/values.yaml

install-grafana-operator: Grafana/helm/values.yaml
	helm upgrade --install ${GRAFANA_RELEASE_NAME} ${GRAFANA_HELM_CHART} \
	    --version ${GRAFANA_HELM_CHART_VERSION} \
		-f Grafana/helm/values.yaml \
		-n ${MONITORING_NAMESPACE}

create-grafana-smtp-secret:
	$(if $(strip $(SMTP_USERNAME)),,$(error SMTP_USERNAME is required))
	$(if $(strip $(SMTP_PASSWORD)),,$(error SMTP_PASSWORD is required))
	kubectl -n "$(MONITORING_NAMESPACE)" create secret generic grafana-smtp \
		--from-literal=GF_SMTP_USER="$(SMTP_USERNAME)" \
		--from-literal=GF_SMTP_PASSWORD="$(SMTP_PASSWORD)"

create-grafana-slack-secret:
	$(if $(strip $(SLACK_WEBHOOK_URL)),,$(error SLACK_WEBHOOK_URL is required))
	kubectl -n "$(MONITORING_NAMESPACE)" create secret generic grafana-slack-webhook \
		--from-literal=url="$(SLACK_WEBHOOK_URL)"

deploy-grafana:
	kubectl -n ${MONITORING_NAMESPACE} apply -f Grafana/kubernetes/

# VictoriaMetrics Commands
add-victoria-metrics-helm-repo:
	helm repo add ${VICTORIA_METRICS_HELM_REPO_NAME} ${VICTORIA_METRICS_HELM_REPO_URL}
	helm repo update

list-victoria-metrics-versions:
	helm search repo ${VICTORIA_METRICS_HELM_CHART} --versions

VictoriaMetrics/helm/values.yaml:
	helm show values ${VICTORIA_METRICS_HELM_CHART} \
	    --version ${VICTORIA_METRICS_HELM_CHART_VERSION} > VictoriaMetrics/helm/values.yaml

install-victoria-metrics: VictoriaMetrics/helm/values.yaml
	helm upgrade --install ${VICTORIA_METRICS_RELEASE_NAME} ${VICTORIA_METRICS_HELM_CHART} \
	    --version ${VICTORIA_METRICS_HELM_CHART_VERSION} \
		-f VictoriaMetrics/helm/values.yaml \
		-n ${MONITORING_NAMESPACE}

# Postgres Commands
list-postgres-versions:
	oras repo tags ${POSTGRES_HELM_REPO}

Postgres/cnpg.yaml:
	wget --output-document Postgres/cnpg.yaml ${POSTGRES_OPERATOR_URL}

install-cnpg: Postgres/cnpg.yaml
	kubectl apply --server-side -f Postgres/cnpg.yaml -n ${CNPG_OPERATOR_NAMESPACE}

deploy-local-path-provisioner:
	kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml

deploy-postgres:
	kubectl -n ${DATABASE_NAMESPACE} apply -f Postgres/grafana-db-user.yaml
	kubectl -n ${DATABASE_NAMESPACE} apply -f Postgres/cluster.yaml

# ShoeHub App Commands
deploy-shoehub-app:
	kubectl -n ${PRODUCTION_NAMESPACE} apply -f App/

# Loki Commands
list-loki-versions:
	helm search repo ${LOKI_HELM_CHART} --versions

Loki/values.yaml:
	helm show values ${LOKI_HELM_CHART} --version ${LOKI_HELM_CHART_VERSION} > Loki/values.yaml

# SeaweedFS Commands
create-seaweedfs-secret:
	kubectl -n ${DATABASE_NAMESPACE} create secret generic seaweedfs-credentials \
		--from-literal access-key='seaweedadmin' \
		--from-literal secret-key='95325476d20db54a227d4419a7c1d2f6eec217ae87a0fd7f'

deploy-seaweedfs:
	kubectl -n ${DATABASE_NAMESPACE} apply -f SeaweedFS/
