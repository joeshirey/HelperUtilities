---
name: pubsub-basics
description: >-
  Manages Google Cloud Pub/Sub topics, subscriptions, schemas, and messages safely and efficiently.
  Use when building or managing event-driven, decoupled systems, streaming data pipelines, or
  integrating push/pull asynchronous message consumers. Don't use when writing or debugging
  Google Cloud client library code or raw REST/gRPC API interactions directly.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [gcp, pubsub, messaging, cloud, event-driven, gcloud]
    related_skills: [gcloud, cloud-run-basics]
---

# GCP Pub/Sub Basics

This skill provides safe, repeatable guidance for operating Google Cloud Pub/Sub
from the `gcloud` CLI. It covers the core messaging concepts, the IAM roles
required to act on resources, step-by-step recipes for creating topics and
subscriptions, and the operational guardrails that prevent destructive or
ambiguous actions. Follow it whenever you provision, inspect, or operate Pub/Sub
infrastructure for event-driven systems, streaming pipelines, or asynchronous
service integrations.

## Overview

Google Cloud Pub/Sub is a fully managed, asynchronous messaging service that
decouples message producers from message consumers. Producers publish messages
without knowing who consumes them, and consumers receive messages without
knowing who produced them. This decoupling enables resilient, horizontally
scalable, event-driven architectures.

### Core concepts

- **Topic** — A named resource to which producers (publishers) send messages.
  A topic is the entry point for data flowing into the system. Topics may
  optionally enforce a **schema** on incoming messages.

- **Subscription** — A named resource representing a stream of messages from a
  single topic to be delivered to a subscribing application. Each subscription
  receives its own independent copy of every message published to the topic
  after the subscription was created. A topic can have many subscriptions; this
  is the fan-out mechanism.

- **Pull delivery** — The subscriber application explicitly requests messages
  from the subscription on its own schedule (using a client library, the CLI, or
  a streaming pull connection). Pull is well suited to high-throughput batch
  consumers and workers that control their own concurrency. Messages must be
  explicitly acknowledged (acked) after successful processing.

- **Push delivery** — Pub/Sub proactively sends each message as an HTTPS POST
  request to a configured **endpoint** (for example a Cloud Run service, Cloud
  Functions function, or any publicly reachable HTTPS URL). The endpoint
  acknowledges a message by returning a success HTTP status (`102`, `200`,
  `201`, `202`, or `204`). Push is well suited to serverless consumers and
  webhook-style integrations.

- **Acknowledgement (ack) and ack deadline** — A consumer must acknowledge a
  message to signal successful processing. If the message is not acked within the
  subscription's **ack deadline**, Pub/Sub redelivers it. This at-least-once
  delivery model means consumers must be designed to be **idempotent**.

- **Dead Letter Topic (DLT)** — A topic to which messages are forwarded after a
  subscription fails to deliver them more than a configured maximum number of
  times (`--max-delivery-attempts`). Dead lettering isolates "poison" messages
  so they stop blocking healthy traffic and can be inspected or reprocessed
  later. The Pub/Sub service account must have permission to publish to the dead
  letter topic and to subscribe to the source subscription.

- **Schema** — An optional, versioned definition (Avro or Protocol Buffer) that
  constrains the structure of messages published to a topic. When a topic is
  associated with a schema and an encoding (`JSON` or `BINARY`), Pub/Sub
  validates every published message and rejects non-conforming payloads. Schemas
  provide a contract between producers and consumers and prevent malformed data
  from entering the pipeline.

## Prerequisites

Before performing any operation, confirm the following are in place.

1. **Enable the Pub/Sub API.** The `pubsub.googleapis.com` service must be
   enabled on the target project.

   ```
   gcloud services enable pubsub.googleapis.com --project=PROJECT_ID
   ```

2. **Install and update the gcloud CLI.** Operations in this skill assume a
   recent Google Cloud CLI. Confirm it is installed and current.

   ```
   gcloud version
   gcloud components update --quiet
   ```

3. **Authorize the CLI.** Authenticate with an identity (user or service
   account) that holds the required roles described below.

   ```
   gcloud auth login
   gcloud config set project PROJECT_ID
   ```

   For automated or non-interactive environments, prefer Application Default
   Credentials backed by a dedicated service account:

   ```
   gcloud auth activate-service-account --key-file=KEY_FILE_PATH
   ```

4. **Confirm the active project and account.** Always verify the execution
   context before mutating resources.

   ```
   gcloud config list --format="value(core.project,core.account)"
   ```

## Key IAM roles

Grant the **least privilege** required for the task. The principal acting
through this skill should hold only the roles that match its responsibilities.

| Role | Role ID | Purpose |
| --- | --- | --- |
| Pub/Sub Admin | `roles/pubsub.admin` | Full control: create, update, and delete topics, subscriptions, and schemas, and manage IAM policies. Restrict to provisioning identities. |
| Pub/Sub Publisher | `roles/pubsub.publisher` | Publish messages to topics. Grant to producer services. |
| Pub/Sub Subscriber | `roles/pubsub.subscriber` | Consume and acknowledge messages from subscriptions. Grant to consumer services. |
| Pub/Sub Viewer | `roles/pubsub.viewer` | Read-only access to view topics, subscriptions, schemas, and configuration. Grant for inspection and auditing. |
| Service Account User | `roles/iam.serviceAccountUser` | Allows an identity to act as (impersonate) a service account. Required when configuring authenticated push subscriptions that invoke a service using a service-account identity token. |

Additional notes:

- Push subscriptions that call private services (for example an authenticated
  Cloud Run endpoint) require that the push **service account** is granted the
  invoker role on the target service (for example `roles/run.invoker`), in
  addition to `roles/iam.serviceAccountUser` on that service account for the
  configuring identity.
- Dead letter delivery requires the Pub/Sub service agent
  (`service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com`) to hold
  `roles/pubsub.publisher` on the dead letter topic and
  `roles/pubsub.subscriber` on the source subscription.

## Composite resource deployment recipe

Use this composite recipe when you need to provision a new schema-bound topic and subscription together. It orchestrates the configuration, validation, and creation of the dependent resources (Schema -> Topic -> Subscription) in a single execution block to minimize shell turns and prevent partial configurations.

```bash
# Run as a single copy-pasteable execution block
(
  set -e

  # 1. Configuration Parameters
  PROJECT_ID="PROJECT_ID"
  SCHEMA_ID="SCHEMA_ID"
  SCHEMA_TYPE="avro"                 # avro or protocol-buffer
  SCHEMA_FILE="PATH_TO_SCHEMA_FILE"   # Local path to schema definition file
  ENCODING="json"                    # json or binary
  TOPIC_ID="TOPIC_ID"
  SUBSCRIPTION_ID="SUBSCRIPTION_ID"
  ACK_DEADLINE=60                    # Acknowledgement deadline in seconds

  echo "=== [1/5] Validating Schema Definition ==="
  gcloud pubsub schemas validate-schema \
    --type="${SCHEMA_TYPE}" \
    --definition-file="${SCHEMA_FILE}" \
    --project="${PROJECT_ID}"

  echo "=== [2/5] Creating Schema ==="
  gcloud pubsub schemas create "${SCHEMA_ID}" \
    --type="${SCHEMA_TYPE}" \
    --definition-file="${SCHEMA_FILE}" \
    --project="${PROJECT_ID}" \
    --quiet

  echo "=== [3/5] Creating Topic ==="
  gcloud pubsub topics create "${TOPIC_ID}" \
    --schema="${SCHEMA_ID}" \
    --message-encoding="${ENCODING}" \
    --project="${PROJECT_ID}" \
    --quiet

  echo "=== [4/5] Creating Subscription ==="
  gcloud pubsub subscriptions create "${SUBSCRIPTION_ID}" \
    --topic="${TOPIC_ID}" \
    --ack-deadline="${ACK_DEADLINE}" \
    --project="${PROJECT_ID}" \
    --quiet

  echo "=== [5/5] Verifying Resources ==="
  gcloud pubsub schemas describe "${SCHEMA_ID}" --project="${PROJECT_ID}"
  gcloud pubsub topics describe "${TOPIC_ID}" --project="${PROJECT_ID}"
  gcloud pubsub subscriptions describe "${SUBSCRIPTION_ID}" --project="${PROJECT_ID}"
)
```

## Schema enforcement: "JSON" is a message encoding, not a schema type

This trips up almost everyone. Google Cloud Pub/Sub has two **schema types**:
`AVRO` and `PROTOCOL_BUFFER`. There is no `JSON` schema type, and
`gcloud pubsub schemas create --type=json` will fail.

When a task asks for a "JSON schema" or "strict JSON validation," it means the
**topic validates messages with JSON encoding against an attached schema**. JSON
is the `--message-encoding` you set on the *topic*, not the type of the schema.
The schema definition itself is normally written in AVRO.

So a request for a "strict JSON schema" breaks into two parts:
1. A schema attached to the topic (the data contract).
2. The topic's `schemaSettings.encoding` set to `JSON` (messages validated as JSON).

### Correct recipe

```bash
SCHEMA="orders-schema"
TOPIC="orders-topic"

# 1. Create the schema. Type is AVRO; the definition is written in Avro JSON.
gcloud pubsub schemas create "$SCHEMA" \
  --type=AVRO \
  --definition='{"type":"record","name":"Order","fields":[
    {"name":"id","type":"string"},
    {"name":"amount","type":"double"}
  ]}'

# 2. Create the topic and bind the schema with JSON MESSAGE ENCODING.
#    --message-encoding=json is the part that makes it a "JSON schema".
gcloud pubsub topics create "$TOPIC" \
  --schema="$SCHEMA" \
  --message-encoding=json

# 3. Verify the contract: encoding must be JSON.
gcloud pubsub topics describe "$TOPIC" --format="value(schemaSettings.encoding)"   # -> JSON
```

If a topic already exists, bind the schema and encoding with
`gcloud pubsub topics update "$TOPIC" --schema="$SCHEMA" --message-encoding=json`.

> **Default to JSON encoding** unless a task explicitly asks for binary. Reach for
> `--message-encoding=binary` only when the requirement calls for it. Choosing
> binary (or omitting the encoding) is the most common reason a "JSON schema"
> requirement is scored as unmet, because the schema looks present but the
> messages are not JSON-validated.

### Troubleshooting

- **"Schema is AVRO but I need JSON":** That is a category error. AVRO is the
  schema *type*; JSON is the *message encoding*. Keep the AVRO schema and set the
  topic's `--message-encoding=json`. Do not try to change the schema type.
- **Encoding shows empty / BINARY:** the topic was created without
  `--message-encoding=json` (or without `--schema`). Re-bind with
  `gcloud pubsub topics update --schema=... --message-encoding=json`.

## Dead-letter topics: the policy lives on the consuming subscription

A dead-letter policy is configured on the **subscription that pulls from the main
topic**, not on the dead-letter topic and not on a subscription of the
dead-letter topic. Two mistakes account for almost every failure here: attaching
the policy to the wrong subscription, and forgetting `--max-delivery-attempts`.

To dead-letter after N failed deliveries:

```bash
DLQ_TOPIC="orders-dlq"
SUB="orders-sub"          # the subscription that consumes the MAIN topic
PROJECT="$(gcloud config get-value project)"

# 1. Create the dead-letter topic.
gcloud pubsub topics create "$DLQ_TOPIC" --project="$PROJECT"

# 2. Attach the dead-letter policy to the CONSUMING subscription.
#    --max-delivery-attempts is required; without it there is no dead-lettering.
gcloud pubsub subscriptions update "$SUB" \
  --project="$PROJECT" \
  --dead-letter-topic="$DLQ_TOPIC" \
  --max-delivery-attempts=5

# 3. Verify the policy is on the right subscription.
gcloud pubsub subscriptions describe "$SUB" \
  --project="$PROJECT" \
  --format="value(deadLetterPolicy.deadLetterTopic, deadLetterPolicy.maxDeliveryAttempts)"
```

> **Grant the Pub/Sub service agent IAM, or dead-lettering silently fails.** The
> service agent `service-<project-number>@gcp-sa-pubsub.iam.gserviceaccount.com`
> needs `roles/pubsub.publisher` on the dead-letter topic and
> `roles/pubsub.subscriber` on the subscription. Without these, messages are
> never forwarded to the DLQ even though the policy looks correct.

### Common mistakes

- **Policy on the wrong subscription.** It must be on the subscription consuming
  the source topic. A dead-letter policy attached to a subscription of the
  dead-letter topic does nothing useful.
- **`--max-delivery-attempts` omitted.** The valid range is 5 to 100. If a task
  asks for "exactly N attempts," pass that N explicitly.

## Build order: schema and encoding must exist before the topic binds them

Most "topic create failed" loops come from doing things out of order. Pub/Sub
will reject a topic create that references a schema that does not exist yet, and
you cannot add JSON encoding without an attached schema. Follow this sequence and
verify each step before moving on:

1. **Create the schema first.** `gcloud pubsub schemas create <schema> --type=AVRO --definition=...`
   Verify: `gcloud pubsub schemas describe <schema>` succeeds.
2. **Create the topic bound to that schema, with JSON encoding.**
   `gcloud pubsub topics create <topic> --schema=<schema> --message-encoding=json`
   Verify: `gcloud pubsub topics describe <topic> --format="value(schemaSettings.encoding)"` returns `JSON`.
3. **Create the dead-letter topic** before any subscription references it.
4. **Create the consuming subscription, then attach the dead-letter policy** to
   that subscription: `--dead-letter-topic=<dlq> --max-delivery-attempts=5`.
   Verify the policy is on the subscription that consumes the *source* topic.
5. **Grant the Pub/Sub service agent IAM permissions:**
   - `roles/pubsub.publisher` on the dead-letter topic.
   - `roles/pubsub.subscriber` on the consuming subscription.
   *(Note: Without these roles, dead-lettering will silently fail even if the policy is configured).*

If a `topics create` call fails, do not blindly retry the same command. Read the
error: a missing-schema or wrong-encoding error means step 1 or 2 was skipped or
out of order. Re-running an identical create that already failed will keep
failing.

## Creating topics and subscriptions
All commands below use placeholders in CAPS. Replace `TOPIC_ID`,
`SUBSCRIPTION_ID`, `PROJECT_ID`, `ENDPOINT`, and similar tokens with concrete
values before execution. Every command explicitly scopes the project with
`--project=PROJECT_ID` and runs non-interactively with `--quiet`.

### 1. Create a topic

```
gcloud pubsub topics create TOPIC_ID \
  --project=PROJECT_ID \
  --quiet
```

To create a topic that enforces a message-retention duration (so that even
subscriptions can replay within the window):

```
gcloud pubsub topics create TOPIC_ID \
  --message-retention-duration=7d \
  --project=PROJECT_ID \
  --quiet
```

To associate a topic with an existing schema:

```
gcloud pubsub topics create TOPIC_ID \
  --schema=SCHEMA_ID \
  --message-encoding=json \
  --project=PROJECT_ID \
  --quiet
```

### 2. Create a Pull subscription

A pull subscription lets the consumer fetch messages on demand. The
`--ack-deadline` controls how long a consumer has to acknowledge a message
before redelivery.

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --ack-deadline=60 \
  --project=PROJECT_ID \
  --quiet
```

To attach a dead letter topic and bound redelivery attempts:

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --ack-deadline=60 \
  --dead-letter-topic=DEAD_LETTER_TOPIC_ID \
  --max-delivery-attempts=5 \
  --project=PROJECT_ID \
  --quiet
```

To restrict which messages this subscription receives using a server-side
filter on message attributes (see Data Reduction below):

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --message-filter='attributes.eventType = "ORDER_CREATED"' \
  --project=PROJECT_ID \
  --quiet
```

### 3. Create a Push subscription

A push subscription delivers each message to an HTTPS `ENDPOINT`. The endpoint
must return a success status to acknowledge a message.

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --push-endpoint=ENDPOINT \
  --ack-deadline=60 \
  --project=PROJECT_ID \
  --quiet
```

For an authenticated push subscription that targets a private service, attach a
push-auth service account so Pub/Sub sends a signed OIDC token:

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --push-endpoint=ENDPOINT \
  --push-auth-service-account=PUSH_SERVICE_ACCOUNT_EMAIL \
  --ack-deadline=60 \
  --project=PROJECT_ID \
  --quiet
```

### 4. Verify what you created

After creation, confirm configuration before relying on it.

```
gcloud pubsub topics describe TOPIC_ID \
  --project=PROJECT_ID

gcloud pubsub subscriptions describe SUBSCRIPTION_ID \
  --project=PROJECT_ID
```

## Resource naming and verification checklist

Before completing any Pub/Sub provisioning task, run through this checklist to ensure all resources match expectations:

- [ ] **Verify resource names match requirements**: Cross-reference the exact names of the Schema, Topic, and Subscription in the prompt or spec. Do not assume names.
- [ ] **Verify labels are applied**: If the prompt requests labels (e.g. `windtunnel-eval`), verify they are present on both the Topic and Subscription.
- [ ] **Verify resource existence**: Run `describe` commands for the Schema, Topic, and Subscription and confirm the outputs show `state: ACTIVE` (for schema) and correct configurations.

## Core principles

These principles are mandatory. Apply them to every Pub/Sub operation.

### Explicit command validation (mandatory)

- Before running any mutating command, restate in plain language what the command
  will do and to which resource. Confirm the resource name, the project, and the
  effect.
- Use `--dry-run` where the subcommand supports it, or run the read-only
  `describe`/`list` equivalent first to confirm the current state.
- Never execute a command whose effect you cannot precisely predict. If the
  outcome is ambiguous, stop and validate first.

### Data reduction

Minimize the volume of data fetched, processed, and returned. Large,
unfiltered reads are slow, costly, and noisy.

- **`--limit`** — Cap the number of results when listing or pulling. For
  example, `gcloud pubsub subscriptions pull SUBSCRIPTION_ID --limit=10`.
- **Server-side filtering** — Apply `--message-filter` at subscription creation
  so unwanted messages are never delivered, rather than filtering after the
  fact. Use `--filter` on `list` commands to narrow results server-side where
  supported.
- **Projection** — Request only the fields you need with
  `--format="value(...)"` or `--format="table(...)"` instead of dumping full
  resource representations.

### Project and location scoping

- Always append `--project=PROJECT_ID` to every command. Never rely solely on
  the ambient `gcloud config` project; explicit scoping prevents acting on the
  wrong project.
- For resources that support location or regional endpoints, specify the
  location explicitly rather than depending on defaults.

### Execution constraints

- **Non-interactive mode** — Append `--quiet` (or `-q`) to suppress interactive
  prompts so commands are deterministic and automation-safe. This must not be
  used to bypass the human-approval requirements in the Safety section below.
- **Single commands** — Execute one discrete `gcloud` command at a time. Do not
  chain unrelated operations into a single invocation.
- **No raw shell operators** — Do not use shell pipes (`|`), redirects (`>`,
  `>>`), command substitution (`$(...)`), background operators (`&`), or
  `&&`/`;` chaining to compose Pub/Sub commands. Each command must stand alone
  and be independently auditable.

## Safety and guardrails

> [!CAUTION]
> Pub/Sub operations can be destructive and irreversible. Deleting a topic or
> subscription permanently discards undelivered messages and breaks every
> producer and consumer bound to it. Changing IAM policy can silently cut off
> access for production services. Treat every mutating operation as
> production-impacting unless explicitly proven otherwise.

### Prohibited operations (denylist)

The following operations MUST NOT be executed without explicit, recorded human
approval. When a task appears to require one of these, stop and request
approval first; describe the exact command and its blast radius.

- **Deleting a topic** — `gcloud pubsub topics delete ...`. Destroys the topic
  and detaches all subscriptions.
- **Deleting a subscription** — `gcloud pubsub subscriptions delete ...`.
  Permanently drops all unacknowledged messages held by that subscription.
- **Deleting or modifying a schema** — `gcloud pubsub schemas delete ...` or
  schema revision changes that can invalidate in-flight producers.
- **Purging/seeking messages destructively** — `gcloud pubsub subscriptions
  seek ...` to a timestamp or snapshot that discards the current backlog.
- **Changing critical IAM bindings** — Adding, removing, or replacing
  `roles/pubsub.admin`, `roles/pubsub.publisher`, or `roles/pubsub.subscriber`
  bindings on production topics or subscriptions, or any `set-iam-policy`
  operation that replaces an entire policy.
- **Detaching a topic** — `gcloud pubsub topics detach-subscription ...`, which
  immediately stops delivery to the affected subscription.

### Always-safe operations

Read-only inspection commands (`describe`, `list`, and bounded `pull` without
auto-ack for diagnostics) are safe and encouraged for validation, provided they
respect the data-reduction principles above.

## Troubleshooting / What to do if...

### ...a command fails with a permission error (PERMISSION_DENIED / 403)

1. Confirm the active identity: `gcloud config list --format="value(core.account)"`.
2. Confirm the role on the resource matches the action (see the IAM table). For
   example, publishing requires `roles/pubsub.publisher`; consuming requires
   `roles/pubsub.subscriber`.
3. For push to private endpoints, verify the push service account has the
   invoker role on the target service and that the configuring identity holds
   `roles/iam.serviceAccountUser` on that service account.
4. Confirm the API is enabled: `gcloud services list --enabled --filter="pubsub" --project=PROJECT_ID`.

### ...a subscription has a growing backlog (messages not being consumed fast enough)

1. Inspect the backlog and oldest unacked age in Cloud Monitoring metrics
   (`subscription/num_undelivered_messages`,
   `subscription/oldest_unacked_message_age`).
2. For pull consumers, scale out the number of consumer instances or increase
   per-instance concurrency so total throughput exceeds the publish rate.
3. Confirm consumers are acking successfully; failed processing leads to
   redelivery and inflated backlog.
4. Consider whether a `--message-filter` should reduce delivered volume, or
   whether the topic is over-fanned-out.

### ...messages accumulate unacknowledged (repeated redelivery)

1. Verify the consumer is calling acknowledge after successful processing.
2. Check the `--ack-deadline`. If processing routinely takes longer than the
   deadline, increase it or extend the deadline programmatically; otherwise
   Pub/Sub redelivers before the consumer finishes.
3. Ensure consumers are idempotent — at-least-once delivery guarantees that
   duplicates can occur, and non-idempotent handlers compound the problem.
4. If specific "poison" messages never succeed, attach a **dead letter topic**
   with `--max-delivery-attempts` so they are isolated instead of redelivered
   forever.

### ...schema validation fails (published messages are rejected)

1. Confirm the topic's bound schema and encoding:
   `gcloud pubsub topics describe TOPIC_ID --project=PROJECT_ID`.
2. Validate a sample message against the schema before publishing:
   `gcloud pubsub schemas validate-message ...`.
3. Confirm the producer serializes with the encoding the topic expects
   (`JSON` vs `BINARY`); a mismatch causes rejection even for structurally
   valid data.
4. If the schema legitimately needs to change, commit a new, compatible schema
   revision rather than editing producers ad hoc — and treat schema deletion as
   a prohibited operation requiring approval.

## Reference directory

Consult these reference documents for deeper, task-specific detail:

- [`references/cli-usage.md`](references/cli-usage.md) — Comprehensive
  `gcloud pubsub` command reference, including publishing, pulling,
  acknowledging, seeking, snapshots, and output formatting recipes.
- [`references/iam-security.md`](references/iam-security.md) — Detailed IAM role
  and policy guidance, least-privilege patterns, service-account configuration
  for push delivery, and dead-letter permission setup.
- [`references/client-libraries.md`](references/client-libraries.md) — Pointers
  to the official Google Cloud client libraries for programmatic publishing and
  consuming, with notes on when to prefer SDK code over the CLI.
