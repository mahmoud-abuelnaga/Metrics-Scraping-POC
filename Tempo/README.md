# Tempo

Tempo is deployed in microservices mode with the maintained
`grafana-community/tempo-distributed` Helm chart.

The deployment uses:

- SeaweedFS S3-compatible storage for trace blocks
- Redpanda as the Kafka-compatible Tempo 3 ingest buffer
- Native Tempo metrics-generator processors for service graphs and span metrics
- VictoriaMetrics as the Prometheus remote-write destination
- Prometheus `ServiceMonitor` and `PrometheusRule` resources, automatically
  converted by VictoriaMetrics Operator

Install or upgrade the complete tracing backend:

```bash
make deploy-tempo
```

The local-path provisioner, VictoriaMetrics stack, and SeaweedFS must already
be installed. The full `make start` workflow installs them in the required
order.

Applications can export OTLP over HTTP to:

```text
http://tempo-distributor.monitoring.svc.cluster.local:4318/v1/traces
```

Grafana queries:

```text
http://tempo-query-frontend.monitoring.svc.cluster.local:3200
```

## Migrating an existing operator deployment

Tempo 3 microservices mode is not an in-place replacement for the Tempo
Operator deployment. Before directing traffic to this release, remove the old
`TempoStack` and Tempo Operator after confirming that the new deployment can
read the shared `tempo-traces` bucket. Do not let Tempo 2 and Tempo 3 compact
the same bucket concurrently.
