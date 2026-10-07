---
title: Who records a DisableDomainEvent
section: Sending domains
order: 10
ask: lib/domainUtils.ts
lede: Seven paths set a sending domain's disabled flag. Two write the event row.
---

A `DisableDomainEvent` is the review record for a disable: admins resolve it as Reenable, Unleash or BlockDomain. Not every disable leaves one.

**Two paths write the event**

- [disableSendingDomain](src:lib/domainUtils.ts#disableSendingDomain) flips the flag, then creates the row. Every automated safety disable funnels here: the health-metrics cron and [handleDisableNewDomain](src:lib/safety-checks/handleDisableDomain.ts#handleDisableNewDomain), which fronts scan-email, the static content check, campaign send, transactional and workflow preflight.
- [Domain creation](src:pages/api/sending-domains/create.ts#/models\.disableDomainEvent/) writes one when a new domain is born disabled.

**Five paths flip the flag alone**

- [saveDomainAssessment, BlockDomain](src:trpc/routers/admin-router.ts#/DisableResolution\.BlockDomain:/) only updates the `decision` on events that already exist.
- [The New Signups bulk disable](src:trpc/routers/admin/bulk-disable-sending-domains.ts#disableNewSignupSendingDomainsForTeams) does the same with an `updateMany` over Pending events, and logs an `AdminPanelInteraction`.
- [markEmailMessageAsUnsafe](src:trpc/routers/admin-router.ts#/markEmailMessageAsUnsafe:/) is a bare flag flip.
- [The SES tenant job](src:jobs/ses-tenant-events.ts#sesTenantEvent) reacts to a `DISABLED` status with a Datadog event only.
- [Team deletion](src:models/team.ts#requestDeletion) writes a `SuspiciousActivity` row instead.

The last two go through [setDisabledByTeamId](src:queries/sending-domain.ts#setDisabledByTeamId), which disables every domain on the team at once.

**Where it bites**

In the two admin paths, a domain with no Pending event matches zero rows: an admin blocking a still-enabled domain leaves it disabled with no event at all.

**Unused**

[The query-layer create](src:queries/disable-domain-event.ts#create) has no caller outside its test. Both writers use the legacy `createRecord` helper.
