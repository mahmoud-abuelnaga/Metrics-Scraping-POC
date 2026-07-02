.PHONY: start-cluster stop-cluster
.PHONY: install-grafana-operator deploy-grafana list-grafana-versions
.PHONY: install-victoria-metrics list-victoria-metrics-versions
.PHONY: install-postgres list-postgres-versions

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
VICTORIA_METRICS_HELM_CHART := vm/victoria-metrics-k8s-stack
VICTORIA_METRICS_HELM_CHART_VERSION := 0.85.6
VICTORIA_METRICS_RELEASE_NAME := vm

# CNPG Variables
CNPG_OPERATOR_URL := https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.1.yaml
CNPG_OPERATOR_NAMESPACE := cnpg-system

# Postgres Variables
POSTGRES_NAMESPACE := database

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

deploy-grafana:
	kubectl -n ${MONITORING_NAMESPACE} apply -f Grafana/kubernetes/

# VictoriaMetrics Commands
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

deploy-postgres:
	kubectl -n ${DATABASE_NAMESPACE} apply -f Postgres/grafana-db-user.yaml
	kubectl -n ${DATABASE_NAMESPACE} apply -f Postgres/cluster.yaml

# App Commands
deploy-app:
	kubectl -n ${PRODUCTION_NAMESPACE} apply -f App/
