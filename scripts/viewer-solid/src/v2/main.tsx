import { render } from "solid-js/web";
import "./v2.css";
import App from "./App";
import { startRouter } from "./router";
import { connect } from "./sync";
import { installPageTelemetry } from "./telemetry";

installPageTelemetry();
connect();
render(() => <App />, document.getElementById("root")!);
startRouter();
