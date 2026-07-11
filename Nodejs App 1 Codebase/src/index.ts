import express from "express";
import { httpLogger, captureResponseBody } from "./logs/http-logger.js";
import { port } from "./global/env-vars.js";
import { errorHandler } from "./middlewares/error-handling.js";
import { shutdown } from "./shutdown.js";

const app = express();

// Starts request timing.
app.use(httpLogger);

// Parses JSON so req.body is available by completion time.
app.use(express.json({ limit: "1mb" }));

// Captures bodies sent through res.json() or res.send().
app.use(captureResponseBody);

// Routes
app.get("/random-number", (_req, res, _next) => {
    const randomNumber = Math.floor(Math.random() * 100);
    return res.json({ randomNumber });
});

app.get("/error", (_req, _res, _next) => {
    throw new Error("Test error");
});

app.post("/replay", (req, res, _next) => {
    return res.json({ message: "Replay", data: req.body });
});

app.use((_req, res, _next) => {
    return res.status(404).json({ message: "Not found" });
});

// Error handling
app.use(errorHandler);

const server = app.listen(port, () => {
    console.log(`Server is running on port ${port}`);
});

process.once("SIGTERM", () => {
    void shutdown("SIGTERM", server);
});

process.once("SIGINT", () => {
    void shutdown("SIGINT", server);
});
