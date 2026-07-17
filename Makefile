.PHONY: start start-cluster wait-cluster configure-etcd-metrics wait-etcd-metrics stop-cluster create-namespaces
.PHONY: install-grafana-operator deploy-grafana wait-grafana list-grafana-versions
.PHONY: create-grafana-smtp-secret create-grafana-slack-secret
.PHONY: add-victoria-metrics-helm-repo install-victoria-metrics list-victoria-metrics-versions
.PHONY: install-cnpg wait-cnpg deploy-postgres wait-postgres list-postgres-versions
.PHONY: deploy-local-path-provisioner wait-local-path-provisioner
.PHONY: deploy-shoehub-app wait-shoehub-app
.PHONY: add-loki-helm-repo install-loki list-loki-versions
.PHONY: create-seaweedfs-secret deploy-seaweedfs wait-seaweedfs

# General Variables
MONITORING_NAMESPACE := monitoring
DATABASE_NAMESPACE := database
PRODUCTION_NAMESPACE := production
WAIT_TIMEOUT ?= 15m
HELM_TIMEOUT ?= 15m
ETCD_WAIT_RETRIES ?= 10
ETCD_RETRY_DELAY ?= 10


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
PROMETHEUS_CRDS_RELEASE_NAME := prometheus-operator-crds
PROMETHEUS_CRDS_HELM_CHART := oci://ghcr.io/prometheus-community/charts/prometheus-operator-crds
PROMETHEUS_CRDS_HELM_CHART_VERSION := 30.0.1

# CNPG Variables
CNPG_OPERATOR_URL := https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.1.yaml
CNPG_OPERATOR_NAMESPACE := cnpg-system

# Loki Variables
LOKI_HELM_REPO_NAME := grafana-community
LOKI_HELM_REPO_URL := https://grafana-community.github.io/helm-charts
LOKI_HELM_CHART := grafana-community/loki
LOKI_HELM_CHART_VERSION := 18.4.4

# Cluster Commands
start:
	$(if $(strip $(SMTP_USERNAME)),,$(error SMTP_USERNAME is required))
	$(if $(strip $(SMTP_PASSWORD)),,$(error SMTP_PASSWORD is required))
	$(if $(strip $(SLACK_WEBHOOK_URL)),,$(error SLACK_WEBHOOK_URL is required))
	./scripts/start-components.sh

start-cluster:
	minikube start --nodes=2 \
		--extra-config=controller-manager.bind-address=0.0.0.0 \
		--extra-config=scheduler.bind-address=0.0.0.0 \
		--cni calico
		# --extra-config=etcd.listen-metrics-urls=http://0.0.0.0:2381 \

wait-cluster:
	kubectl wait --for=condition=Ready node --all --timeout=$(WAIT_TIMEOUT)

configure-etcd-metrics:
	minikube ssh -- "sudo grep -q -- '--listen-metrics-urls=http://0.0.0.0:2381' /etc/kubernetes/manifests/etcd.yaml || sudo sed -Ei 's|--listen-metrics-urls=[^[:space:]]+|--listen-metrics-urls=http://0.0.0.0:2381|' /etc/kubernetes/manifests/etcd.yaml"
	minikube ssh -- "sudo grep -q -- '--listen-metrics-urls=http://0.0.0.0:2381' /etc/kubernetes/manifests/etcd.yaml"

wait-etcd-metrics:
	@attempt=1; \
	while [ "$$attempt" -le "$(ETCD_WAIT_RETRIES)" ]; do \
		if kubectl -n kube-system get pod -l component=etcd -o jsonpath='{.items[*].spec.containers[0].command}' | grep -Fq -- '--listen-metrics-urls=http://0.0.0.0:2381'; then \
			echo "etcd pod is using the all-interface metrics listener"; \
			break; \
		fi; \
		if [ "$$attempt" -eq "$(ETCD_WAIT_RETRIES)" ]; then \
			echo "etcd pod did not pick up the metrics listener after $(ETCD_WAIT_RETRIES) attempts" >&2; \
			exit 1; \
		fi; \
		echo "etcd configuration check failed (attempt $$attempt/$(ETCD_WAIT_RETRIES)); retrying in $(ETCD_RETRY_DELAY)s"; \
		sleep "$(ETCD_RETRY_DELAY)"; \
		attempt=$$((attempt + 1)); \
	done
	@attempt=1; \
	while [ "$$attempt" -le "$(ETCD_WAIT_RETRIES)" ]; do \
		if kubectl -n kube-system get pod -l component=etcd -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | grep -qw true; then \
			echo "etcd pod is ready"; \
			break; \
		fi; \
		if [ "$$attempt" -eq "$(ETCD_WAIT_RETRIES)" ]; then \
			echo "etcd pod was not ready after $(ETCD_WAIT_RETRIES) attempts" >&2; \
			exit 1; \
		fi; \
		echo "etcd readiness check failed (attempt $$attempt/$(ETCD_WAIT_RETRIES)); retrying in $(ETCD_RETRY_DELAY)s"; \
		sleep "$(ETCD_RETRY_DELAY)"; \
		attempt=$$((attempt + 1)); \
	done
	@node_ip="$$(minikube ip)"; \
	attempt=1; \
	while [ "$$attempt" -le "$(ETCD_WAIT_RETRIES)" ]; do \
		if minikube ssh -- "curl --fail --silent --show-error http://$$node_ip:2381/health >/dev/null"; then \
			echo "etcd metrics endpoint is reachable at http://$$node_ip:2381"; \
			break; \
		fi; \
		if [ "$$attempt" -eq "$(ETCD_WAIT_RETRIES)" ]; then \
			echo "etcd metrics endpoint was not reachable after $(ETCD_WAIT_RETRIES) attempts" >&2; \
			exit 1; \
		fi; \
		echo "etcd endpoint check failed (attempt $$attempt/$(ETCD_WAIT_RETRIES)); retrying in $(ETCD_RETRY_DELAY)s"; \
		sleep "$(ETCD_RETRY_DELAY)"; \
		attempt=$$((attempt + 1)); \
	done

stop-cluster:
	minikube stop

create-namespaces:
	kubectl create namespace ${MONITORING_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace ${CNPG_OPERATOR_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace ${DATABASE_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace ${PRODUCTION_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -


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
		-n ${MONITORING_NAMESPACE} \
		--wait --timeout $(HELM_TIMEOUT)

create-grafana-smtp-secret:
	$(if $(strip $(SMTP_USERNAME)),,$(error SMTP_USERNAME is required))
	$(if $(strip $(SMTP_PASSWORD)),,$(error SMTP_PASSWORD is required))
	@kubectl -n "$(MONITORING_NAMESPACE)" create secret generic grafana-smtp \
		--from-literal=GF_SMTP_USER="$(SMTP_USERNAME)" \
		--from-literal=GF_SMTP_PASSWORD="$(SMTP_PASSWORD)" \
		--dry-run=client -o yaml | kubectl apply -f -

create-grafana-slack-secret:
	$(if $(strip $(SLACK_WEBHOOK_URL)),,$(error SLACK_WEBHOOK_URL is required))
	@kubectl -n "$(MONITORING_NAMESPACE)" create secret generic grafana-slack-webhook \
		--from-literal=url="$(SLACK_WEBHOOK_URL)" \
		--dry-run=client -o yaml | kubectl apply -f -

deploy-grafana:
	kubectl -n ${MONITORING_NAMESPACE} apply -f Grafana/kubernetes/

wait-grafana:
	kubectl -n ${MONITORING_NAMESPACE} wait --for=create deployment/grafana-deployment --timeout=$(WAIT_TIMEOUT)
	kubectl -n ${MONITORING_NAMESPACE} rollout status deployment/grafana-deployment --timeout=$(WAIT_TIMEOUT)

# VictoriaMetrics Commands
add-victoria-metrics-helm-repo:
	helm repo add ${VICTORIA_METRICS_HELM_REPO_NAME} ${VICTORIA_METRICS_HELM_REPO_URL} || true
	helm repo update

list-victoria-metrics-versions:
	helm search repo ${VICTORIA_METRICS_HELM_CHART} --versions

VictoriaMetrics/helm/values.yaml:
	helm show values ${VICTORIA_METRICS_HELM_CHART} \
	    --version ${VICTORIA_METRICS_HELM_CHART_VERSION} > VictoriaMetrics/helm/values.yaml

install-victoria-metrics: VictoriaMetrics/helm/values.yaml
	helm upgrade --install ${PROMETHEUS_CRDS_RELEASE_NAME} \
        ${PROMETHEUS_CRDS_HELM_CHART} \
        --version ${PROMETHEUS_CRDS_HELM_CHART_VERSION} \
		--namespace ${MONITORING_NAMESPACE} \
		--wait --timeout $(HELM_TIMEOUT)

	helm upgrade --install ${VICTORIA_METRICS_RELEASE_NAME} ${VICTORIA_METRICS_HELM_CHART} \
	    --version ${VICTORIA_METRICS_HELM_CHART_VERSION} \
		-f VictoriaMetrics/helm/values.yaml \
		-n ${MONITORING_NAMESPACE} \
		--wait --timeout $(HELM_TIMEOUT)

# Postgres Commands
list-postgres-versions:
	oras repo tags ${POSTGRES_HELM_REPO}

Postgres/cnpg.yaml:
	wget --output-document Postgres/cnpg.yaml ${POSTGRES_OPERATOR_URL}

install-cnpg: Postgres/cnpg.yaml
	kubectl apply --server-side -f Postgres/cnpg.yaml -n ${CNPG_OPERATOR_NAMESPACE}

wait-cnpg:
	kubectl -n ${CNPG_OPERATOR_NAMESPACE} rollout status deployment/cnpg-controller-manager --timeout=$(WAIT_TIMEOUT)

deploy-local-path-provisioner:
	kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml

wait-local-path-provisioner:
	kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=$(WAIT_TIMEOUT)

deploy-postgres:
	kubectl -n ${DATABASE_NAMESPACE} apply -f Postgres/grafana-db-user.yaml
	kubectl -n ${DATABASE_NAMESPACE} apply -f Postgres/cluster.yaml

wait-postgres:
	kubectl -n ${DATABASE_NAMESPACE} wait --for=condition=Ready cluster/grafana-db --timeout=$(WAIT_TIMEOUT)

# ShoeHub App Commands
deploy-shoehub-app:
	kubectl -n ${PRODUCTION_NAMESPACE} apply -f App/

wait-shoehub-app:
	kubectl -n ${PRODUCTION_NAMESPACE} rollout status deployment/shoehub-app --timeout=$(WAIT_TIMEOUT)

# Loki Commands
add-loki-helm-repo:
	helm repo add ${LOKI_HELM_REPO_NAME} ${LOKI_HELM_REPO_URL} || true
	helm repo update

list-loki-versions:
	helm search repo ${LOKI_HELM_CHART} --versions

Loki/values.yaml:
	helm show values ${LOKI_HELM_CHART} --version ${LOKI_HELM_CHART_VERSION} > Loki/values.yaml

install-loki: Loki/values.yaml
	helm upgrade --install loki \
		${LOKI_HELM_CHART} \
		--version ${LOKI_HELM_CHART_VERSION} \
		-n ${MONITORING_NAMESPACE} \
		-f Loki/values.yaml \
		--wait --timeout $(HELM_TIMEOUT)

# SeaweedFS Commands
create-seaweedfs-secret:
	@kubectl -n ${DATABASE_NAMESPACE} create secret generic seaweedfs-credentials \
		--from-literal access-key='seaweedadmin' \
		--from-literal secret-key='95325476d20db54a227d4419a7c1d2f6eec217ae87a0fd7f' \
		--dry-run=client -o yaml | kubectl apply -f -

	@kubectl -n ${MONITORING_NAMESPACE} create secret generic seaweedfs-credentials \
		--from-literal access-key='seaweedadmin' \
		--from-literal secret-key='95325476d20db54a227d4419a7c1d2f6eec217ae87a0fd7f' \
		--dry-run=client -o yaml | kubectl apply -f -

deploy-seaweedfs:
	kubectl -n ${DATABASE_NAMESPACE} apply -f SeaweedFS/

wait-seaweedfs:
	kubectl -n ${DATABASE_NAMESPACE} rollout status statefulset/seaweedfs --timeout=$(WAIT_TIMEOUT)
