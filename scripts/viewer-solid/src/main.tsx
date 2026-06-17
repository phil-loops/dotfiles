import { render } from "solid-js/web";
import { QueryClient, QueryClientProvider } from "@tanstack/solid-query";
import "diff2html/bundles/css/diff2html.min.css";
import "./index.css";
import App from "./App";

// One client for the whole app. solid-query handles what NODEPATCH + the SWR caches +
// the timeout/retry hand-rolling did — caching, dedup, stale-while-revalidate, retries —
// declaratively, per query key.
const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 30_000, retry: 2, refetchOnWindowFocus: false },
  },
});

render(
  () => (
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  ),
  document.getElementById("root")!
);
