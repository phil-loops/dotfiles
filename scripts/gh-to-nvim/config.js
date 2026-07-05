// Single source of truth for the viewer's base URL. Loaded first in the content
// script, via importScripts in the service worker, and via <script> in the popup —
// so content.js / background.js / popup.js all read the SAME constant. This is the
// multi-repo entry server (loops' :62497); it serves every repo's forest and routes
// each request by the GitHub `repo` slug every payload already carries, so non-loops
// PRs (e.g. monotoad) open against the right checkout without a second port here.
const VIEWER_URL = "http://localhost:62497";
const VIEWER_PORT = new URL(VIEWER_URL).port;
