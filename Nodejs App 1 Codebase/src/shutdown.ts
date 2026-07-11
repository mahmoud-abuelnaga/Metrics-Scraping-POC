import type { Server } from "node:http";
import { shutdownTelemetry } from "./instrumentation.js";

let isShuttingDown = false;

async function closeHttpServer(server: Server): Promise<void> {
    await new Promise<void>((resolve) => {
        const forceShutdownTimer = setTimeout(() => {
            console.error(
                "Graceful shutdown timed out. Forcing TCP connections to close.",
            );

            server.closeAllConnections();
            process.exitCode = 1;
        }, 10_000);

        forceShutdownTimer.unref();

        server.close((error) => {
            clearTimeout(forceShutdownTimer);

            if (error) {
                console.error("HTTP server shutdown failed", error);
                process.exitCode = 1;
            }

            resolve();
        });
    });
}

async function shutdown(signal: NodeJS.Signals, server: Server): Promise<void> {
    if (isShuttingDown) return;
    isShuttingDown = true;

    console.log(`${signal} received; shutting down`);

    try {
        // Finish active HTTP requests first.
        await closeHttpServer(server);
    } finally {
        // Flush and stop telemetry last.
        await shutdownTelemetry();
    }
}

export { shutdown };
