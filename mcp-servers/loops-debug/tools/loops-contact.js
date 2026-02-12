const { z } = require("zod");
const { query } = require("../lib/db");

const schema = {
  name: "loops_contact",
  description:
    "High-level contact inspection and manipulation. Provides convenient operations for finding contacts, inspecting their full state (attributes, properties, mailing lists), and updating attributes.",
  inputSchema: {
    op: z
      .enum(["find", "inspect", "update_attribute", "list_properties"])
      .describe("Operation to perform"),
    email: z.string().optional().describe("Contact email (for find/inspect)"),
    contactId: z.string().optional().describe("Contact ID (for inspect/update_attribute)"),
    teamId: z.string().optional().describe("Team ID (for list_properties)"),
    attribute: z.string().optional().describe("Attribute key (for update_attribute)"),
    value: z.any().optional().describe("Attribute value (for update_attribute, omit to remove)"),
  },
};

async function execute({ op, email, contactId, teamId, attribute, value }) {
  switch (op) {
    case "find":
      return await findContact(email, contactId);
    case "inspect":
      return await inspectContact(email, contactId);
    case "update_attribute":
      return await updateAttribute(contactId, attribute, value);
    case "list_properties":
      return await listProperties(teamId, email, contactId);
    default:
      return { content: [{ type: "text", text: `Unknown op: ${op}` }], isError: true };
  }
}

async function findContact(email, contactId) {
  let result;
  if (contactId) {
    result = await query(
      'SELECT id, email, "teamId", attributes, "createdAt", "updatedAt" FROM "Contact" WHERE id = $1',
      [contactId]
    );
  } else if (email) {
    result = await query(
      'SELECT id, email, "teamId", attributes, "createdAt", "updatedAt" FROM "Contact" WHERE email = $1',
      [email]
    );
  } else {
    return { content: [{ type: "text", text: "Error: email or contactId required" }], isError: true };
  }
  return { content: [{ type: "text", text: JSON.stringify(result.rows, null, 2) }] };
}

async function inspectContact(email, contactId) {
  const findResult = contactId
    ? await query('SELECT * FROM "Contact" WHERE id = $1', [contactId])
    : email
    ? await query('SELECT * FROM "Contact" WHERE email = $1', [email])
    : null;

  if (!findResult || findResult.rowCount === 0) {
    return { content: [{ type: "text", text: "Contact not found" }], isError: true };
  }

  const contact = findResult.rows[0];

  const propsResult = await query(
    'SELECT * FROM "ContactProperty" WHERE "teamId" = $1 ORDER BY name',
    [contact.teamId]
  );

  const mlResult = await query(
    `SELECT ml.id, ml."friendlyName", mlc.subscribed, mlc."createdAt" as "subscribedAt"
     FROM "MailingListContact" mlc
     JOIN "MailingList" ml ON ml.id = mlc."mailingListId"
     WHERE mlc."contactId" = $1`,
    [contact.id]
  );

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(
          {
            contact,
            contactProperties: propsResult.rows,
            mailingLists: mlResult.rows,
          },
          null,
          2
        ),
      },
    ],
  };
}

async function updateAttribute(contactId, attribute, value) {
  if (!contactId) {
    return { content: [{ type: "text", text: "Error: contactId required" }], isError: true };
  }
  if (!attribute) {
    return { content: [{ type: "text", text: "Error: attribute required" }], isError: true };
  }

  const current = await query('SELECT attributes FROM "Contact" WHERE id = $1', [contactId]);
  if (current.rowCount === 0) {
    return { content: [{ type: "text", text: "Contact not found" }], isError: true };
  }

  const attrs = current.rows[0].attributes || {};
  if (value === undefined || value === null) {
    delete attrs[attribute];
  } else {
    attrs[attribute] = value;
  }

  const result = await query(
    'UPDATE "Contact" SET attributes = $1, "updatedAt" = NOW() WHERE id = $2 RETURNING id, attributes',
    [JSON.stringify(attrs), contactId]
  );

  return { content: [{ type: "text", text: JSON.stringify(result.rows[0], null, 2) }] };
}

async function listProperties(teamId, email, contactId) {
  if (!teamId) {
    let contact;
    if (contactId) {
      contact = await query('SELECT "teamId" FROM "Contact" WHERE id = $1', [contactId]);
    } else if (email) {
      contact = await query('SELECT "teamId" FROM "Contact" WHERE email = $1 LIMIT 1', [email]);
    }
    if (contact && contact.rowCount > 0) {
      teamId = contact.rows[0].teamId;
    } else {
      return {
        content: [{ type: "text", text: "Error: teamId, email, or contactId required" }],
        isError: true,
      };
    }
  }

  const result = await query(
    'SELECT * FROM "ContactProperty" WHERE "teamId" = $1 ORDER BY name',
    [teamId]
  );

  return { content: [{ type: "text", text: JSON.stringify(result.rows, null, 2) }] };
}

module.exports = { schema, execute };
