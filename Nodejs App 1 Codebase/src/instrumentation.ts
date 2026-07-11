import { NodeSDK } from "@opentelemetry/sdk-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-proto";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import {
    defaultResource,
    resourceFromAttributes,
} from "@opentelemetry/resources";
import { PrometheusExporter } from "@opentelemetry/exporter-prometheus";
import {
    otelServiceName,
    otelServiceVersion,
    nodeEnv,
    prometheusPort,
    prometheusEndpoint,
    prometheusHost,
} from "./global/env-vars.js";

const prometheusExporter = new PrometheusExporter(
    {
        port: Number(prometheusPort),
        host: prometheusHost,
        endpoint: prometheusEndpoint,
    },
    (error) => {
        if (error) {
            console.error("Failed to start Prometheus exporter", error);
        }
    },
);

const sdk = new NodeSDK({
    resource: defaultResource().merge(
        resourceFromAttributes({
            "service.name": otelServiceName,
            "service.version": otelServiceVersion,
            "deployment.environment.name": nodeEnv,
        }),
    ),

    traceExporter: new OTLPTraceExporter(),
    metricReaders: [prometheusExporter],

    instrumentations: [
        getNodeAutoInstrumentations({
            "@opentelemetry/instrumentation-fs": {
                enabled: false,
            },

            "@opentelemetry/instrumentation-http": {
                // Avoid recording a trace and HTTP metric every time
                // Prometheus scrapes the exporter.
                ignoreIncomingRequestHook(request) {
                    const pathname = request.url?.split("?", 1)[0];

                    return (
                        request.socket.localPort === Number(prometheusPort) &&
                        pathname === prometheusEndpoint
                    );
                },
            },
        }),
    ],
});

sdk.start();

async function shutdownTelemetry(): Promise<void> {
    try {
        await sdk.shutdown();
        console.log("OpenTelemetry shut down");
    } catch (error) {
        console.error("Failed to shut down OpenTelemetry SDK", error);
        process.exitCode = 1;
    }
}

// process.once("SIGTERM", shutdown);
// process.once("SIGINT", shutdown);

export { sdk, shutdownTelemetry };
