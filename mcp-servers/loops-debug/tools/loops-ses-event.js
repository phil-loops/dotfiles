const { z } = require("zod");
const { getBaseUrl } = require("../lib/config");
const { query } = require("../lib/db");

const schema = {
  name: "loops_ses_event",
  description:
    "Simulate an SES email event (Delivery, Open, Click, Bounce, Complaint, Send) on an email in the local dev server. Find emails by emailId, contactEmail, or campaignId.",
  inputSchema: {
    eventType: z
      .enum(["Delivery", "Open", "Click", "Bounce", "Complaint", "Send"])
      .describe("The SES event type to simulate"),
    emailId: z
      .string()
      .optional()
      .describe("Email record ID (if known)"),
    contactEmail: z
      .string()
      .optional()
      .describe("Contact email address — picks most recent email sent to this contact"),
    campaignId: z
      .string()
      .optional()
      .describe("Campaign ID — picks most recent email from this campaign"),
    bounceType: z
      .enum(["hard", "soft"])
      .default("hard")
      .optional()
      .describe("Bounce type (only for Bounce events)"),
  },
};

async function findEmailId({ emailId, contactEmail, campaignId }) {
  if (emailId) return emailId;

  if (contactEmail) {
    const result = await query(
      `SELECT e.id FROM "Email" e
       JOIN "Contact" c ON c.id = e."contactId"
       WHERE c.email = $1
       ORDER BY e."createdAt" DESC LIMIT 1`,
      [contactEmail]
    );
    if (result.rows.length === 0) {
      throw new Error(`No emails found for contact: ${contactEmail}`);
    }
    return result.rows[0].id;
  }

  if (campaignId) {
    const result = await query(
      `SELECT e.id FROM "Email" e
       WHERE e."campaignId" = $1
       ORDER BY e."createdAt" DESC LIMIT 1`,
      [campaignId]
    );
    if (result.rows.length === 0) {
      throw new Error(`No emails found for campaign: ${campaignId}`);
    }
    return result.rows[0].id;
  }

  throw new Error("Provide one of: emailId, contactEmail, or campaignId");
}

async function execute({ eventType, emailId, contactEmail, campaignId, bounceType }) {
  const resolvedEmailId = await findEmailId({ emailId, contactEmail, campaignId });

  const baseUrl = getBaseUrl();
  const url = `${baseUrl}/api/dev/simulate-ses-event`;

  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      emailId: resolvedEmailId,
      eventType,
      bounceType,
    }),
  });

  const body = await response.json();

  if (!response.ok) {
    return {
      content: [{ type: "text", text: `Error (${response.status}): ${JSON.stringify(body, null, 2)}` }],
      isError: true,
    };
  }

  return {
    content: [{ type: "text", text: JSON.stringify(body, null, 2) }],
  };
}

module.exports = { schema, execute };
