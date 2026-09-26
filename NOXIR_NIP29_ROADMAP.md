# Noxir — NIP-29 Relay-Side Support (Roadmap)

Status: **planned, not started**. Bastion currently runs against a
relay with zero NIP-29 awareness; all group behavior is client-side
and ungated. This document phases the relay-side work so gating and
canonical channel/group metadata can land when needed.

Reference: `NIP-29.md` (repo root). Client-side counterpart:
`~/code/bastion/bastion-web.md` (Phase B/C notes).

## Current state (baseline)

- No kind 39000–39005 generation, no 9000–9020 handling.
- No membership store; `ALLOWED_PUBKEYS` is the only access control.
- Events carry `h` tags but the relay treats them as ordinary tags.

## R1 — Group metadata emission

Relay-signed, relay-generated state per NIP-29 ("Group metadata
events"):

- Persist groups: id, name/about/picture/banner, `private` /
  `restricted` / `hidden` / `closed` flags, `supported_kinds`,
  subgroups (`parent` / `child` tags).
- Sign + publish kind **39000** (metadata), **39001** (admins),
  **39002** (members, optional) from the relay master key on every
  state change; `d` tag = group id.
- Accept/serve `{kinds: [39000]}` REQs; hide metadata for non-members
  of `hidden` groups.
- Bootstrap path: operator config or a first-admin command creates the
  initial group(s).

Acceptance: clients can discover groups/channels purely via
`{kinds:[39000]}` REQs and build the subgroup tree.

## R2 — Membership lifecycle

- Accept **kind 9021** (join request) / **9022** (leave request),
  including invite-code handling (`closed` groups).
- Emit **9000 put-user / 9001 remove-user** moderation events in
  response.
- Membership store keyed by (group id, pubkey); self-membership
  semantics = latest of 9000/9001 for that user in that group.
- Per-group independent membership (subgroups inherit nothing).

Acceptance: a user's membership status is fully reconstructable from
the canonical 9000/9001 sequence.

## R3 — Enforcement

- Reject EVENTs to `restricted` groups from non-members (OK false,
  clear message); reject reads of `private` groups' events for
  non-member REQs.
- `closed` groups ignore 9021 unless a valid invite `code`.
- Admin authorization for 9000–9020 against kind 39001 roles +
  internal policy (kind 39003 role definitions optional here).
- `previous` tag continuity checks (references must resolve against
  this relay's store) and late-publication rejection (configurable
  skew window).
- Cycle/existence validation for subgroup reparenting via 9002.

Acceptance: an open dev group behaves exactly as today (no policy =
permissive defaults), while a configured private/closed group enforces
end-to-end.

## R4 — Extras

- Remaining admin kinds: 9002 edit-metadata, 9005 delete-event,
  9007 create-group, 9008 delete-group, 9009 create-invite,
  9010 update-pin-list (+ 39005 pins mirror).
- Kind 39003 roles advertisement; kind 39004 LiveKit participants
  (only if AV is ever wanted).
- NIP-11 advertisement: `"nip29": {"subgroups": true}`.
- Migration/fork affordances are out of scope until requested.

## Non-goals

- Becoming a Buzz-class application server. Enforcement is policy
  plumbing around a dumb store; heavy features (git ACLs, media)
  stay in their own layers.
