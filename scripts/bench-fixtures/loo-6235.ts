// The local state LOO-6235's bench replays against: a team whose sending domain is disabled, holding one published
// transactional email (for the send claim) and one with an unpublished draft (for the publish claim), plus an API key.
// Run by `bench setup` from a loops checkout (the cwd), against that checkout's dev database. Safe to run again: it
// reuses the team it made. The last line it prints is the JSON `bench setup` reads: {"team", "key"}.
import { join } from "node:path";

const from = (path: string) => import(join(process.cwd(), path));
const TEAM = "Bench: LOO-6235 disabled domain";
const content = (text: string) => ({
  root: { type: "root", format: "", indent: 0, version: 1, children: [{ type: "text", text, format: "", detail: 0, version: 1 }] },
});

async function main() {
  if (!/@(localhost|127\.0\.0\.1)[:/]/.test(process.env.DATABASE_URL ?? "")) {
    throw new Error("DATABASE_URL is not a local database; this fixture only writes to a local one");
  }
  const { default: prisma } = await from("lib/prisma.ts");
  const { createApiKey } = await from("lib/api-key.ts");

  let team = await prisma.team.findFirst({ where: { name: TEAM } });
  if (!team) {
    team = await prisma.team.create({ data: { name: TEAM, campaignSizeLimit: 1 } });
    const domain = await prisma.sendingDomain.create({
      data: { teamId: team.id, name: "bench-loo-6235.test", domain: "bench-loo-6235.test", address: "1 Bench St\nTestville, CA 90000", isSendableByProvider: true },
    });
    const message = (subject: string) =>
      prisma.emailMessage.create({ data: { teamId: team.id, sendingDomainId: domain.id, subject, fromName: "Bench", fromEmail: "bench", emailContent: content(subject) } });
    const [published, draft] = [await message("Published before the disable"), await message("Draft waiting to publish")];
    await prisma.transactional.create({
      data: { teamId: team.id, name: "Bench: published", description: "sent by the send claim", emoji: "📬", publishedEmailId: published.id, publishedEmailAt: new Date() },
    });
    await prisma.transactional.create({
      data: { teamId: team.id, name: "Bench: draft only", description: "published by the publish claim", emoji: "📝", draftEmailId: draft.id },
    });
  }
  for (const message of await prisma.emailMessage.findMany({ where: { teamId: team.id } })) {
    if (!(message.emailContent as { root?: unknown })?.root) {
      await prisma.emailMessage.update({ where: { id: message.id }, data: { emailContent: content(message.subject) } });
    }
  }
  await prisma.sendingDomain.updateMany({ where: { teamId: team.id }, data: { disabled: true } });

  let key = (await prisma.apiKey.findFirst({ where: { teamId: team.id } }))?.id;
  if (!key) {
    const user =
      (await prisma.user.findFirst({ where: { teamId: team.id } })) ??
      (await prisma.user.create({ data: { name: "Bench", email: `bench-loo-6235@example.com`, teamId: team.id } }));
    key = (await createApiKey({ name: "bench", teamId: team.id, createdByUserId: user.id })).id;
  }
  console.log(JSON.stringify({ team: team.name, key }));
}

main().then(() => process.exit(0), (error) => { console.error(error); process.exit(1); });
