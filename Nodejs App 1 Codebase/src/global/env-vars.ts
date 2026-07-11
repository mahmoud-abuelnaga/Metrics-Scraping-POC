const logLevel = process.env.LOG_LEVEL || "info";
const otelServiceName = process.env.OTEL_SERVICE_NAME || "app-1";
const otelServiceVersion = process.env.OTEL_SERVICE_VERSION || "1.0.0";
const prometheusHost = process.env.PROMETHEUS_HOST || "0.0.0.0";
const prometheusEndpoint = process.env.PROMETHEUS_ENDPOINT || "/metrics";
const prometheusPort = process.env.OTEL_PROMETHEUS_PORT || "9464";
const nodeEnv = process.env.NODE_ENV || "development";
const port = process.env.PORT || "3000";
const shutdownGracePeriod = process.env.SHUTDOWN_GRACE_PERIOD || "10s";

export {
    logLevel,
    otelServiceName,
    nodeEnv,
    port,
    otelServiceVersion,
    prometheusPort,
    prometheusEndpoint,
    prometheusHost,
    shutdownGracePeriod,
};
