// workflow-overlay.mjs — the workflow BUILDER write-operations, which the upstream
// OpenAPI spec (app.loops.so/openapi.json) doesn't yet document (it covers read/GET
// routes only). loops-postman merges these into the spec before generating, so the
// Postman collection actually exercises the builder.
//
// Source of truth: pages/api/v1/workflows/** on the node-creation-revised line.
// The create-node body is the NEW discriminated union on `insertMode`
// ("between" = fromNodeId+toNodeId · "before" = beforeNodeId) — not the old
// fromNodeId/toNodeId shape. `expectedRevisionId` is the optimistic-concurrency
// token: pass the workflow's current `workflowRevisionId` (null on a fresh workflow),
// re-read it from each response/GET before the next write.

const rev = { type: "string", nullable: true, description: "Optimistic-concurrency token — the current workflowRevisionId (null on a fresh workflow)." };
const nodeType = {
  type: "string",
  enum: ["TimerAction", "SendEmailAction", "BranchNode", "ExperimentBranchNode", "AudienceFilter", "VariantNode"],
  example: "TimerAction",
  description:
    "Node to create. Actions: TimerAction, SendEmailAction. Branches: BranchNode / ExperimentBranchNode (each auto-creates its arms). " +
    "AudienceFilter / VariantNode are valid only directly under a branch / experiment. " +
    "Triggers (Signup/Event/ContactProperty/AddToList/Blank) and ExitAction cannot be created.",
};
const queuedPolicy = { type: "string", enum: ["fail", "discard"], description: "What to do with contacts queued on the deleted node." };
const wfId = { name: "workflowId", in: "path", required: true, schema: { type: "string" } };
const nodeId = { name: "nodeId", in: "path", required: true, schema: { type: "string" } };
const jsonBody = (schema, required = true) => ({ required, content: { "application/json": { schema } } });
const ok = { "200": { description: "Success" }, "400": { description: "Validation error" }, "409": { description: "Revision conflict" } };

export const WORKFLOW_OVERLAY = {
  "/v1/workflows": {
    post: {
      tags: ["Workflows"],
      summary: "Create a workflow",
      requestBody: jsonBody({ type: "object", required: ["name"], properties: { name: { type: "string", example: "My workflow" } } }),
      responses: ok,
    },
  },
  "/v1/workflows/{workflowId}": {
    patch: {
      tags: ["Workflows"],
      summary: "Update workflow properties",
      parameters: [wfId],
      requestBody: jsonBody({ type: "object", properties: { name: { type: "string" }, description: { type: "string" }, expectedRevisionId: rev } }),
      responses: ok,
    },
  },
  "/v1/workflows/{workflowId}/nodes": {
    post: {
      tags: ["Workflows"],
      summary: "Create a workflow node (insert between two nodes, or before a node)",
      parameters: [wfId],
      requestBody: jsonBody({
        oneOf: [
          {
            type: "object", title: "insert between",
            required: ["insertMode", "nodeTypeName", "fromNodeId", "toNodeId"],
            properties: { insertMode: { type: "string", enum: ["between"] }, nodeTypeName: nodeType, fromNodeId: { type: "string", example: "n1" }, toNodeId: { type: "string", example: "n2" }, expectedRevisionId: rev },
          },
          {
            type: "object", title: "insert before",
            required: ["insertMode", "nodeTypeName", "beforeNodeId"],
            properties: { insertMode: { type: "string", enum: ["before"] }, nodeTypeName: nodeType, beforeNodeId: { type: "string", example: "n2" }, expectedRevisionId: rev },
          },
        ],
      }),
      responses: ok,
    },
  },
  "/v1/workflows/{workflowId}/nodes/{nodeId}": {
    post: {
      tags: ["Workflows"],
      summary: "Update a node's payload",
      parameters: [wfId, nodeId],
      requestBody: jsonBody({ type: "object", required: ["payload"], properties: { payload: { type: "object", description: "Node-type-specific fields, e.g. { \"amount\": 3, \"unit\": \"d\" } for a TimerAction.", example: { amount: 3, unit: "d" } }, expectedRevisionId: rev } }),
      responses: ok,
    },
    delete: {
      tags: ["Workflows"],
      summary: "Delete a single node (non-recursive)",
      parameters: [wfId, nodeId],
      requestBody: jsonBody({ type: "object", properties: { expectedRevisionId: rev, queuedContactPolicy: queuedPolicy } }, false),
      responses: ok,
    },
  },
  "/v1/workflows/{workflowId}/nodes/{nodeId}/recursive": {
    delete: {
      tags: ["Workflows"],
      summary: "Recursively delete a node and its subtree",
      parameters: [wfId, nodeId],
      requestBody: jsonBody({ type: "object", properties: { expectedRevisionId: rev, queuedContactPolicy: queuedPolicy } }, false),
      responses: ok,
    },
  },
  "/v1/workflows/{workflowId}/nodes/{nodeId}/add-branch": {
    post: {
      tags: ["Workflows"],
      summary: "Add a branch child (filter arm) to a Branch/Experiment node",
      parameters: [wfId, nodeId],
      requestBody: jsonBody({ type: "object", properties: { expectedRevisionId: rev } }, false),
      responses: ok,
    },
  },
  "/v1/workflows/{workflowId}/mailing-list": {
    post: {
      tags: ["Workflows"],
      summary: "Set the workflow's trigger mailing list",
      parameters: [wfId],
      requestBody: jsonBody({ type: "object", required: ["mailingListId"], properties: { mailingListId: { type: "string" }, expectedRevisionId: rev } }),
      responses: ok,
    },
  },
};

// Non-destructive merge: only add a path+method the spec doesn't already document,
// so a future upstream spec that gains these wins over the overlay.
export function mergeWorkflowOverlay(spec) {
  spec.paths ??= {};
  let added = 0;
  for (const [path, methods] of Object.entries(WORKFLOW_OVERLAY)) {
    const existing = (spec.paths[path] ??= {});
    for (const [method, op] of Object.entries(methods)) {
      if (!existing[method]) { existing[method] = op; added++; }
    }
  }
  return added;
}
