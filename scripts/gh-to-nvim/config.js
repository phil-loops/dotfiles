// Single source of truth for the viewer's base URL. Loaded first in the content
// script, via importScripts in the service worker, and via <script> in the popup —
// so content.js / background.js / popup.js all read the SAME constant. The viewer's
// per-repo port (stack-review-port) is pinned here once; change it in this one place.
const VIEWER_URL = "http://localhost:62497";
const VIEWER_PORT = new URL(VIEWER_URL).port;
