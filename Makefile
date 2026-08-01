.PHONY: start start-cluster wait-cluster provision-alloy-data-dirs configure-etcd-metrics wait-etcd-metrics stop-cluster create-namespaces
.PHONY: install-grafana-operator deploy-grafana wait-grafana list-grafana-versions
.PHONY: create-grafana-smtp-secret create-grafana-slack-secret
.PHONY: add-victoria-metrics-helm-repo install-victoria-metrics list-victoria-metrics-versions create-alertmanager-smtp-secret
.PHONY: install-cnpg wait-cnpg deploy-postgres wait-postgres
.PHONY: deploy-local-path-provisioner wait-local-path-provisioner
.PHONY: deploy-shoehub-app wait-shoehub-app
.PHONY: add-loki-helm-repo install-loki list-loki-versions
.PHONY: create-seaweedfs-secret deploy-seaweedfs wait-seaweedfs
.PHONY: add-redpanda-helm-repo list-redpanda-versions install-tempo-kafka wait-tempo-kafka
.PHONY: list-tempo-versions create-tempo-s3-secret deploy-tempo wait-tempo
.PHONY: add-grafana-alloy-helm-repo list-grafana-alloy-versions deploy-grafana-alloy-logs
.PHONY: build-nodejs-app-1 deploy-nodejs-app-1 restart-nodejs-app-1 wait-nodejs-app-1

# Set shell flags to exit on error and print commands
.SHELLFLAGS := -ec

# General Variables
MONITORING_NAMESPACE := monitoring
DATABASE_NAMESPACE := database
PRODUCTION_NAMESPACE := production
WAIT_TIMEOUT ?= 15m
HELM_TIMEOUT ?= 15m
ETCD_WAIT_RETRIES ?= 10
ETCD_RETRY_DELAY ?= 10
DOCKER_REGISTRY ?= "abuelnaga0"
KIND_CLUSTER_NAME ?= metrics-scraping-poc
KIND_CONTEXT := kind-$(KIND_CLUSTER_NAME)
KIND_CONFIG ?= kind-config.yaml
CALICO_VERSION ?= v3.32.1
CALICO_MANIFEST_URL := https://raw.githubusercontent.com/projectcalico/calico/$(CALICO_VERSION)/manifests/calico.yaml

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

# Grafana Alloy Variables
GRAFANA_ALLOY_HELM_REPO_NAME := grafana
GRAFANA_ALLOY_HELM_REPO_URL := https://grafana.github.io/helm-charts
GRAFANA_ALLOY_HELM_CHART := grafana/alloy
GRAFANA_ALLOY_HELM_CHART_VERSION := 1.10.1
GRAFANA_ALLOY_LOGS_RELEASE_NAME := grafana-alloy-logs

# Tempo Variables
TEMPO_HELM_CHART := oci://ghcr.io/grafana-community/helm-charts/tempo-distributed
TEMPO_HELM_CHART_REPOSITORY := ghcr.io/grafana-community/helm-charts/tempo-distributed
TEMPO_HELM_CHART_VERSION := 3.0.6
TEMPO_RELEASE_NAME := tempo
TEMPO_VALUES_FILE := Tempo/helm/values.yaml

# Tempo 3 requires a Kafka-compatible system in microservices mode.
REDPANDA_HELM_REPO_NAME := redpanda
REDPANDA_HELM_REPO_URL := https://charts.redpanda.com
REDPANDA_HELM_CHART := redpanda/redpanda
REDPANDA_HELM_CHART_VERSION := 26.1.8
REDPANDA_RELEASE_NAME := tempo-kafka
REDPANDA_VALUES_FILE := Tempo/redpanda/values.yaml

# Cluster Commands
# start-cluster blocks on Calico because nodes stay NotReady until the CNI is
# serving, and every later target schedules pods that need working networking.
start:
	$(if $(strip $(SMTP_USERNAME)),,$(error SMTP_USERNAME is required))
	$(if $(strip $(SMTP_PASSWORD)),,$(error SMTP_PASSWORD is required))
	$(if $(strip $(SLACK_WEBHOOK_URL)),,$(error SLACK_WEBHOOK_URL is required))
	$(if $(strip $(GMAIL_PASSWORD)),,$(error GMAIL_PASSWORD is required))
	./scripts/start-components.sh

start-cluster:
	@if kind get clusters | grep -Fxq "$(KIND_CLUSTER_NAME)"; then \
		echo "Using existing kind cluster $(KIND_CLUSTER_NAME)"; \
		kubectl config use-context "$(KIND_CONTEXT)"; \
	else \
		kind create cluster --name "$(KIND_CLUSTER_NAME)" --config "$(KIND_CONFIG)"; \
	fi
	kubectl --context "$(KIND_CONTEXT)" apply -f "$(CALICO_MANIFEST_URL)"
	kubectl apply --context "$(KIND_CONTEXT)" -f \
    https://raw.githubusercontent.com/projectcalico/calico/465e3b93ad346abf475051ccc5d32c43b1e214fd/libcalico-go/config/crd/crd.projectcalico.org_tiers.yaml
	kubectl --context "$(KIND_CONTEXT)" -n kube-system rollout status \
		daemonset/calico-node --timeout=$(WAIT_TIMEOUT)
	kubectl --context "$(KIND_CONTEXT)" -n kube-system rollout status \
		deployment/calico-kube-controllers --timeout=$(WAIT_TIMEOUT)

wait-cluster:
	kubectl wait --for=condition=Ready node --all --timeout=$(WAIT_TIMEOUT)

provision-alloy-data-dirs:
	@set -e; \
	for node_name in $$(kind get nodes --name "$(KIND_CLUSTER_NAME)"); do \
		echo "Provisioning Alloy storage on $$node_name"; \
		docker exec "$$node_name" install -d -o 473 -g 473 -m 0750 /var/lib/alloy; \
	done

configure-etcd-metrics:
	@control_plane="$$(kind get nodes --name "$(KIND_CLUSTER_NAME)" | grep -- '-control-plane$$' | head -n 1)"; \
	if [ -z "$$control_plane" ]; then \
		echo "Could not find the kind control-plane node" >&2; \
		exit 1; \
	fi; \
	docker exec "$$control_plane" sh -c \
		"grep -q -- '--listen-metrics-urls=http://0.0.0.0:2381' /etc/kubernetes/manifests/etcd.yaml || sed -Ei 's|--listen-metrics-urls=[^[:space:]]+|--listen-metrics-urls=http://0.0.0.0:2381|' /etc/kubernetes/manifests/etcd.yaml"; \
	docker exec "$$control_plane" grep -q -- '--listen-metrics-urls=http://0.0.0.0:2381' /etc/kubernetes/manifests/etcd.yaml

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
	@control_plane="$$(kind get nodes --name "$(KIND_CLUSTER_NAME)" | grep -- '-control-plane$$' | head -n 1)"; \
	if [ -z "$$control_plane" ]; then \
		echo "Could not find the kind control-plane node" >&2; \
		exit 1; \
	fi; \
	node_ip="$$(kubectl --context "$(KIND_CONTEXT)" get node "$$control_plane" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"; \
	attempt=1; \
	while [ "$$attempt" -le "$(ETCD_WAIT_RETRIES)" ]; do \
		if docker exec "$$control_plane" curl --fail --silent --show-error "http://$$node_ip:2381/health" >/dev/null; then \
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
	kind delete cluster --name "$(KIND_CLUSTER_NAME)"

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

create-alertmanager-smtp-secret:
	$(if $(strip $(GMAIL_PASSWORD)),,$(error GMAIL_PASSWORD is required))
	@echo "Creating AlertManager SMTP secret..."
	kubectl -n ${MONITORING_NAMESPACE} create secret generic alertmanager-smtp \
		--from-literal password='$(GMAIL_PASSWORD)' \
		--dry-run=client -o yaml | kubectl apply -f -

install-victoria-metrics: VictoriaMetrics/helm/values.yaml
	@kubectl -n ${MONITORING_NAMESPACE} get secret alertmanager-smtp >/dev/null 2>&1 || { \
		echo "Secret 'alertmanager-smtp' not found in namespace '${MONITORING_NAMESPACE}'." >&2; \
		echo "Create it first: make create-alertmanager-smtp-secret GMAIL_PASSWORD=<gmail-app-password>" >&2; \
		exit 1; \
	}

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
# CNPG ships as a plain manifest, not a Helm chart, so the operator version is
# pinned by CNPG_OPERATOR_URL rather than discoverable via a repo listing.
Postgres/cnpg.yaml:
	wget --output-document Postgres/cnpg.yaml ${CNPG_OPERATOR_URL}

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

# Grafana Alloy Commands
add-grafana-alloy-helm-repo:
	helm repo add ${GRAFANA_ALLOY_HELM_REPO_NAME} ${GRAFANA_ALLOY_HELM_REPO_URL} || true
	helm repo update

list-grafana-alloy-versions:
	helm search repo ${GRAFANA_ALLOY_HELM_CHART} --versions

GrafanaAlloy/values.logs.yaml:
	helm show values ${GRAFANA_ALLOY_HELM_CHART} --version ${GRAFANA_ALLOY_HELM_CHART_VERSION} > GrafanaAlloy/values.logs.yaml

deploy-grafana-alloy-logs: GrafanaAlloy/values.logs.yaml
	helm upgrade --install ${GRAFANA_ALLOY_LOGS_RELEASE_NAME} \
		${GRAFANA_ALLOY_HELM_CHART} \
		--version ${GRAFANA_ALLOY_HELM_CHART_VERSION} \
		-n ${MONITORING_NAMESPACE} \
		-f GrafanaAlloy/values.logs.yaml \
		--wait --timeout $(HELM_TIMEOUT)

# Deploy Nodejs App 1
.ONESHELL:
build-nodejs-app-1:
	GIT_SHA=$$(git describe --always --dirty)
	docker build -t ${DOCKER_REGISTRY}/nodejs-app-1:latest -f 'Nodejs App 1 Codebase/Dockerfile' 'Nodejs App 1 Codebase/'
	docker tag ${DOCKER_REGISTRY}/nodejs-app-1:latest ${DOCKER_REGISTRY}/nodejs-app-1:$$GIT_SHA
	docker push ${DOCKER_REGISTRY}/nodejs-app-1:latest
	docker push ${DOCKER_REGISTRY}/nodejs-app-1:$$GIT_SHA
	IMAGE_TAG=$$GIT_SHA envsubst < NodejsApp1/nodejs-app-1-deployment.yaml | kubectl apply -f -

.ONESHELL:
deploy-nodejs-app-1:
	IMAGE_TAG=$$(curl -s "https://hub.docker.com/v2/repositories/${DOCKER_REGISTRY}/nodejs-app-1/tags/?page_size=1&ordering=last_updated" \
  | jq -r '.results[0].name')

	IMAGE_TAG=$$IMAGE_TAG envsubst < NodejsApp1/nodejs-app-1-deployment.yaml | kubectl apply -f -
	kubectl apply -f NodejsApp1/nodejs-app-1-service.yaml
	kubectl apply -f NodejsApp1/nodejs-app-1-vmservicescrape.yaml


restart-nodejs-app-1:
	kubectl -n ${PRODUCTION_NAMESPACE} rollout restart deployment/nodejs-app-1

wait-nodejs-app-1:
	kubectl -n ${PRODUCTION_NAMESPACE} rollout status deployment/nodejs-app-1 --timeout=$(WAIT_TIMEOUT)

.ONESHELL:
deploy-nodejs-app-2:
	IMAGE_TAG=$$(curl -s "https://hub.docker.com/v2/repositories/${DOCKER_REGISTRY}/nodejs-app-1/tags/?page_size=1&ordering=last_updated" \
  | jq -r '.results[0].name')

	IMAGE_TAG=$$IMAGE_TAG envsubst < NodejsApp2/nodejs-app-2-deployment.yaml | kubectl apply -f -
	kubectl apply -f NodejsApp2/nodejs-app-2-service.yaml
	kubectl apply -f NodejsApp2/nodejs-app-2-vmservicescrape.yaml

restart-nodejs-app-2:
	kubectl -n ${PRODUCTION_NAMESPACE} rollout restart deployment/nodejs-app-2

wait-nodejs-app-2:
	kubectl -n ${PRODUCTION_NAMESPACE} rollout status deployment/nodejs-app-2 --timeout=$(WAIT_TIMEOUT)

# Tempo Commands
add-redpanda-helm-repo:
	helm repo add ${REDPANDA_HELM_REPO_NAME} ${REDPANDA_HELM_REPO_URL} || true
	helm repo update ${REDPANDA_HELM_REPO_NAME}

list-redpanda-versions: add-redpanda-helm-repo
	helm search repo ${REDPANDA_HELM_CHART} --versions

install-tempo-kafka: create-namespaces add-redpanda-helm-repo
	helm upgrade --install ${REDPANDA_RELEASE_NAME} ${REDPANDA_HELM_CHART} \
		--version ${REDPANDA_HELM_CHART_VERSION} \
		--namespace ${MONITORING_NAMESPACE} \
		-f ${REDPANDA_VALUES_FILE} \
		--wait --timeout $(HELM_TIMEOUT)

wait-tempo-kafka:
	kubectl -n ${MONITORING_NAMESPACE} rollout status statefulset/tempo-kafka --timeout=$(WAIT_TIMEOUT)

list-tempo-versions:
	oras repo tags ${TEMPO_HELM_CHART_REPOSITORY}

create-tempo-s3-secret: create-namespaces
	@set -eu; \
	access_key="$$(kubectl -n $(DATABASE_NAMESPACE) get secret seaweedfs-credentials -o jsonpath='{.data.access-key}' | base64 -d)"; \
	secret_key="$$(kubectl -n $(DATABASE_NAMESPACE) get secret seaweedfs-credentials -o jsonpath='{.data.secret-key}' | base64 -d)"; \
	kubectl -n $(MONITORING_NAMESPACE) create secret generic tempo-s3 \
		--from-literal=S3_ACCESS_KEY="$$access_key" \
		--from-literal=S3_SECRET_KEY="$$secret_key" \
		--from-literal=S3_BUCKET="tempo-traces" \
		--from-literal=S3_ENDPOINT="seaweedfs.database.svc.cluster.local:8333" \
		--dry-run=client -o yaml | kubectl apply -f -

deploy-tempo: install-tempo-kafka create-tempo-s3-secret
	helm upgrade --install ${TEMPO_RELEASE_NAME} ${TEMPO_HELM_CHART} \
		--version ${TEMPO_HELM_CHART_VERSION} \
		--namespace ${MONITORING_NAMESPACE} \
		-f ${TEMPO_VALUES_FILE} \
		--wait --timeout $(HELM_TIMEOUT)

wait-tempo:
	kubectl -n ${MONITORING_NAMESPACE} wait \
		--for=condition=Ready pod \
		--selector=app.kubernetes.io/instance=${TEMPO_RELEASE_NAME} \
		--timeout=$(WAIT_TIMEOUT)
