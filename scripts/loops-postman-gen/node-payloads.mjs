// node-payloads.mjs — the per-node-type shapes of the `payload` object on
//   POST /v1/workflows/{workflowId}/nodes/{nodeId}
//
// The wire schema is only `payload: object` — the real field set is chosen at runtime by
// the *existing node's* type, so no static spec can name it. Without this table the console
// can only show an opaque blob; with it, every field a node accepts is a row you can add.
//
// Source of truth: lib/workflow-operations/edit-operations/node-operations/*.ts (patchSchema).
// EventTrigger tracks PR #9550 (eventName as an alternative to eventPatternId).

const TABLE_FILTER_OPERATION = [
  "any", "contains", "not_contains", "empty", "not_empty", "equal", "not_equal",
  "greater_than", "less_than", "true", "false", "numeric_equal", "numeric_not_equal",
  "date_empty", "date_not_empty", "after", "before", "between", "campaign",
  "any_loop_email", "specific_loop_email", "accepted_opt_in", "rejected_opt_in",
  "pending_opt_in", "not_opt_in",
];

const reEligible = {
  type: "boolean",
  description: "Let a contact enter the workflow again if they re-trigger it.",
};

// Triggers accept `typeName` naming a *different* trigger, which swaps the node's type
// instead of patching it.
const typeName = (self) => ({
  type: "string",
  enum: ["SignupTrigger", "EventTrigger", "ContactPropertyTrigger", "AddToListTrigger"],
  example: self,
  description:
    "Only to change this trigger into another kind of trigger. Omit it (or repeat " +
    self + ") to patch the fields below. You cannot switch a trigger to BlankTrigger.",
});

export const NODE_PAYLOAD_SHAPES = {
  SignupTrigger: {
    properties: { typeName: typeName("SignupTrigger") },
    note: "A signup trigger has nothing to patch — the only legal payload is a typeName that turns it into another trigger.",
  },

  EventTrigger: {
    properties: {
      typeName: typeName("EventTrigger"),
      eventPatternId: {
        type: "string",
        nullable: true,
        example: "eventpattern_123",
        description: "Pick the event by its id. Send null to detach the event from the trigger.",
      },
      eventName: {
        type: "string",
        nullable: true,
        example: "User Signed Up",
        description:
          "Pick the event by name instead of id — the name is resolved to an event on your team. Send null to detach.",
      },
      reEligible,
    },
    exclusive: [["eventPatternId", "eventName"]],
    atLeastOne: true,
  },

  ContactPropertyTrigger: {
    properties: {
      typeName: typeName("ContactPropertyTrigger"),
      contactPropertyQuery: {
        type: "object",
        description: "Fire when a contact property changes from `was` to `is`.",
        example: {
          key: "plan",
          was: { value: "free", operator: "equal" },
          is: { value: "pro", operator: "equal" },
        },
        properties: {
          key: { type: "string", description: "The contact property to watch." },
          is: { type: "object", description: "Its value after the change. operator: " + TABLE_FILTER_OPERATION.join(" · ") },
          was: { type: "object", description: "Its value before the change." },
        },
        required: ["key", "is", "was"],
      },
      reEligible,
    },
    atLeastOne: true,
  },

  AddToListTrigger: {
    properties: { typeName: typeName("AddToListTrigger"), reEligible },
    atLeastOne: true,
    note: "The mailing list itself is set through POST /v1/workflows/{workflowId}/mailing-list, not here.",
  },

  BlankTrigger: {
    properties: { typeName: typeName("BlankTrigger") },
    note: "A blank trigger has nothing to patch — send a typeName to turn it into a real trigger.",
  },

  AudienceFilter: {
    properties: {
      audienceSegmentId: {
        type: "string",
        nullable: true,
        example: "segment_123",
        description: "Filter on a saved segment. Sending this on its own clears any inline filter.",
      },
      audienceFilter: {
        type: "object",
        nullable: true,
        description:
          "An inline filter. Sending this on its own clears the saved segment. match: all | any. " +
          "Each condition is one of type: property · optIn · activity.",
        example: {
          match: "all",
          conditions: [{ type: "property", key: "plan", operator: "equals", value: "pro" }],
        },
      },
      appliesDownstream: {
        type: "boolean",
        description: "Keep applying this filter to contacts already past this node.",
      },
    },
    atLeastOne: true,
  },

  TimerAction: {
    properties: {
      amount: { type: "number", example: 3, description: "How long to wait." },
      unit: { type: "string", enum: ["m", "h", "d", "s"], description: "minutes · hours · days · seconds" },
    },
    atLeastOne: true,
  },

  ExperimentBranchNode: {
    properties: {
      experimentType: { type: "string", enum: ["webhook", "autosplit"] },
      samplingRate: { type: "number", example: 50, description: "Percent of contacts entering the experiment." },
      experimentId: { type: "string", example: "exp_123" },
      url: { type: "string", example: "https://example.com/experiment", description: "Webhook experiments only." },
    },
    atLeastOne: true,
  },

  VariantNode: {
    properties: { isControl: { type: "boolean", description: "Make this arm the control." } },
    atLeastOne: true,
  },

  SendEmailAction: { properties: {}, note: "Not patchable — the API answers every payload with WorkflowOperationNotImplemented." },
  ExitAction: { properties: {}, note: "Not patchable — the API answers every payload with WorkflowOperationNotImplemented." },
  BranchNode: { properties: {}, note: "Not patchable — the API answers every payload with WorkflowOperationNotImplemented. Add arms with POST .../add-branch." },
};
