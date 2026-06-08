# Pub/Sub CLI Deep-Dive Reference

A comprehensive `gcloud pubsub` command reference for advanced topic,
subscription, and schema workflows. Every command uses CAPS placeholders
(`TOPIC_ID`, `SUBSCRIPTION_ID`, `PROJECT_ID`, …) — replace them with concrete
values before running. Commands scope the project explicitly with
`--project=PROJECT_ID` and run non-interactively with `--quiet` where a prompt
would otherwise appear.

> [!CAUTION]
> Deletions, destructive seeks, detaches, and IAM policy replacements are
> irreversible and production-impacting. See the parent
> [`SKILL.md`](../SKILL.md) safety section before running any mutating command.

## Conventions used in this document

| Placeholder | Meaning |
| --- | --- |
| `PROJECT_ID` | Target Google Cloud project ID. |
| `PROJECT_NUMBER` | Numeric project number (used in service-agent emails). |
| `TOPIC_ID` | Short topic name (not the full `projects/.../topics/...` path). |
| `SUBSCRIPTION_ID` | Short subscription name. |
| `SCHEMA_ID` | Short schema name. |
| `SNAPSHOT_ID` | Short snapshot name. |
| `DEAD_LETTER_TOPIC_ID` | Topic that receives undeliverable messages. |
| `ENDPOINT` | HTTPS URL for push delivery. |
| `LOCATION` | KMS key location / region (e.g. `us-central1`). |

Most commands accept either the short ID or the fully-qualified resource path
(`projects/PROJECT_ID/topics/TOPIC_ID`). The short ID is used throughout; the
full path is required only when a referenced resource lives in a different
project (e.g. a cross-project dead-letter topic).

---

## 1. Topics management

### 1.1 Create a basic topic

```
gcloud pubsub topics create TOPIC_ID \
  --project=PROJECT_ID \
  --quiet
```

### 1.2 Create a topic with message retention

`--message-retention-duration` makes the topic retain published messages so new
or seeking subscriptions can replay them. Accepts a duration string
(`s`, `m`, `h`, `d`); valid range is `10m` to `31d` (the documented maximum is
31 days).

```
gcloud pubsub topics create TOPIC_ID \
  --message-retention-duration=7d \
  --project=PROJECT_ID \
  --quiet
```

### 1.3 Create a topic with a schema

The schema must already exist (see §3). `--message-encoding` is required when a
schema is attached and must be `json` or `binary`. Optionally pin the accepted
revision range with `--first-revision-id` / `--last-revision-id`.

```
gcloud pubsub topics create TOPIC_ID \
  --schema=SCHEMA_ID \
  --message-encoding=json \
  --project=PROJECT_ID \
  --quiet
```

Pin a schema revision range (messages validated against any revision in
`[FIRST, LAST]`):

```
gcloud pubsub topics create TOPIC_ID \
  --schema=SCHEMA_ID \
  --message-encoding=binary \
  --first-revision-id=FIRST_REVISION_ID \
  --last-revision-id=LAST_REVISION_ID \
  --project=PROJECT_ID \
  --quiet
```

### 1.4 Create a topic with a customer-managed encryption key (CMEK)

Pass the KMS key either as one fully-qualified resource string or as discrete
component flags. The Pub/Sub service agent must hold
`roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key.

Single fully-qualified key:

```
gcloud pubsub topics create TOPIC_ID \
  --topic-encryption-key=projects/PROJECT_ID/locations/LOCATION/keyRings/KEYRING_ID/cryptoKeys/KEY_ID \
  --project=PROJECT_ID \
  --quiet
```

Component flags (equivalent):

```
gcloud pubsub topics create TOPIC_ID \
  --topic-encryption-key=KEY_ID \
  --topic-encryption-key-keyring=KEYRING_ID \
  --topic-encryption-key-location=LOCATION \
  --topic-encryption-key-project=KMS_PROJECT_ID \
  --project=PROJECT_ID \
  --quiet
```

Grant the service agent access to the key beforehand:

```
gcloud kms keys add-iam-policy-binding KEY_ID \
  --keyring=KEYRING_ID \
  --location=LOCATION \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --project=KMS_PROJECT_ID \
  --quiet
```

### 1.5 Restrict message storage regions (data residency)

```
gcloud pubsub topics create TOPIC_ID \
  --message-storage-policy-allowed-regions=us-central1,us-east1 \
  --project=PROJECT_ID \
  --quiet
```

### 1.6 List topics

```
gcloud pubsub topics list \
  --project=PROJECT_ID
```

Project only the topic name as plain values:

```
gcloud pubsub topics list \
  --format="value(name)" \
  --project=PROJECT_ID
```

Filter server-side by name substring:

```
gcloud pubsub topics list \
  --filter="name:orders" \
  --project=PROJECT_ID
```

### 1.7 Describe a topic

```
gcloud pubsub topics describe TOPIC_ID \
  --project=PROJECT_ID
```

Project only the bound schema settings:

```
gcloud pubsub topics describe TOPIC_ID \
  --format="value(schemaSettings.schema, schemaSettings.encoding)" \
  --project=PROJECT_ID
```

### 1.8 List the subscriptions attached to a topic

```
gcloud pubsub topics list-subscriptions TOPIC_ID \
  --project=PROJECT_ID
```

### 1.9 Update a topic

Change retention, labels, or the storage policy after creation:

```
gcloud pubsub topics update TOPIC_ID \
  --message-retention-duration=14d \
  --project=PROJECT_ID \
  --quiet
```

Clear retention entirely:

```
gcloud pubsub topics update TOPIC_ID \
  --clear-message-retention-duration \
  --project=PROJECT_ID \
  --quiet
```

### 1.10 Delete a topic (prohibited without approval)

```
gcloud pubsub topics delete TOPIC_ID \
  --project=PROJECT_ID \
  --quiet
```

Deleting a topic detaches all of its subscriptions. Requires recorded human
approval per the skill's denylist.

### 1.11 Publish messages

Simple message body:

```
gcloud pubsub topics publish TOPIC_ID \
  --message="MESSAGE_BODY" \
  --project=PROJECT_ID
```

With attributes (`KEY=VALUE` pairs, comma-separated):

```
gcloud pubsub topics publish TOPIC_ID \
  --message="MESSAGE_BODY" \
  --attribute=eventType=ORDER_CREATED,region=us \
  --project=PROJECT_ID
```

With an ordering key (consumers must enable message ordering on the
subscription to receive in order — see §2.1):

```
gcloud pubsub topics publish TOPIC_ID \
  --message="MESSAGE_BODY" \
  --ordering-key=CUSTOMER_42 \
  --project=PROJECT_ID
```

Combined attributes + ordering key:

```
gcloud pubsub topics publish TOPIC_ID \
  --message="MESSAGE_BODY" \
  --attribute=eventType=ORDER_CREATED \
  --ordering-key=CUSTOMER_42 \
  --project=PROJECT_ID
```

Publish an attribute-only message (empty data payload):

```
gcloud pubsub topics publish TOPIC_ID \
  --attribute=heartbeat=true \
  --project=PROJECT_ID
```

---

## 2. Subscriptions management

### 2.1 Create a Pull subscription

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --ack-deadline=60 \
  --project=PROJECT_ID \
  --quiet
```

Common Pull flags:

| Flag | Purpose |
| --- | --- |
| `--ack-deadline=SECONDS` | Seconds (10–600) a consumer has to ack before redelivery. |
| `--message-retention-duration=DURATION` | How long unacked messages are retained (`10m`–`7d`; default `7d`). |
| `--retain-acked-messages` | Keep acked messages within the retention window (enables seek-back). |
| `--expiration-period=DURATION` | Auto-delete the subscription after this idle period. |
| `--no-expiration` | Never auto-delete the subscription. |
| `--enable-message-ordering` | Deliver messages with the same ordering key in order. |
| `--enable-exactly-once-delivery` | Stronger no-duplicate guarantee for pull. |
| `--message-filter=EXPRESSION` | Server-side attribute filter; non-matching messages are never delivered. |

Pull subscription with retention + ordering + exactly-once:

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --ack-deadline=120 \
  --message-retention-duration=3d \
  --retain-acked-messages \
  --enable-message-ordering \
  --enable-exactly-once-delivery \
  --project=PROJECT_ID \
  --quiet
```

With a dead-letter topic and bounded redelivery:

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --ack-deadline=60 \
  --dead-letter-topic=DEAD_LETTER_TOPIC_ID \
  --max-delivery-attempts=5 \
  --project=PROJECT_ID \
  --quiet
```

If the dead-letter topic lives in another project, add
`--dead-letter-topic-project=DLT_PROJECT_ID`. The Pub/Sub service agent
(`service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com`) needs
`roles/pubsub.publisher` on the dead-letter topic and `roles/pubsub.subscriber`
on this subscription.

With a retry (exponential backoff) policy:

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --min-retry-delay=10s \
  --max-retry-delay=600s \
  --project=PROJECT_ID \
  --quiet
```

### 2.2 Create a Push subscription

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --push-endpoint=ENDPOINT \
  --ack-deadline=60 \
  --project=PROJECT_ID \
  --quiet
```

Authenticated push to a private service (Pub/Sub sends a signed OIDC token):

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --push-endpoint=ENDPOINT \
  --push-auth-service-account=PUSH_SERVICE_ACCOUNT_EMAIL \
  --push-auth-token-audience=AUDIENCE \
  --ack-deadline=60 \
  --project=PROJECT_ID \
  --quiet
```

Deliver the raw message without the Pub/Sub JSON envelope (no-wrapper / payload
unwrapping):

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --push-endpoint=ENDPOINT \
  --push-no-wrapper \
  --push-no-wrapper-write-metadata \
  --project=PROJECT_ID \
  --quiet
```

### 2.3 Create a BigQuery subscription

Delivers messages directly into a BigQuery table. The table is referenced as
`PROJECT_ID:DATASET_ID.TABLE_ID` (colon between project and dataset). Choose
exactly one schema source: `--use-topic-schema`, `--use-table-schema`, or
neither (writes the message into a single `data` column).

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --bigquery-table=PROJECT_ID:DATASET_ID.TABLE_ID \
  --use-table-schema \
  --project=PROJECT_ID \
  --quiet
```

With Pub/Sub message metadata columns and lenient field handling:

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --bigquery-table=PROJECT_ID:DATASET_ID.TABLE_ID \
  --use-topic-schema \
  --write-metadata \
  --drop-unknown-fields \
  --project=PROJECT_ID \
  --quiet
```

| Flag | Purpose |
| --- | --- |
| `--bigquery-table=PROJECT:DATASET.TABLE` | Destination table. |
| `--use-topic-schema` | Map topic-schema fields to table columns. |
| `--use-table-schema` | Map message fields to the existing table schema. |
| `--write-metadata` | Add columns for `subscription_name`, `message_id`, `publish_time`, `attributes`, `data`. |
| `--drop-unknown-fields` | Drop message fields absent from the table schema instead of failing. |

The Pub/Sub service agent needs `roles/bigquery.dataEditor` on the dataset.

### 2.4 Create a Cloud Storage subscription

Batches messages into objects written to a GCS bucket. Files are flushed when
either the byte threshold or the duration window is reached.

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --cloud-storage-bucket=BUCKET_NAME \
  --cloud-storage-file-prefix=PREFIX_ \
  --cloud-storage-file-suffix=.txt \
  --cloud-storage-max-bytes=10000000 \
  --cloud-storage-max-duration=300s \
  --project=PROJECT_ID \
  --quiet
```

Write Avro-formatted files (optionally including message metadata):

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=TOPIC_ID \
  --cloud-storage-bucket=BUCKET_NAME \
  --cloud-storage-output-format=avro \
  --cloud-storage-write-metadata \
  --cloud-storage-max-duration=300s \
  --project=PROJECT_ID \
  --quiet
```

| Flag | Purpose |
| --- | --- |
| `--cloud-storage-bucket=BUCKET_NAME` | Destination bucket (name only, no `gs://`). |
| `--cloud-storage-file-prefix=PREFIX` | Filename prefix for written objects. |
| `--cloud-storage-file-suffix=SUFFIX` | Filename suffix (e.g. `.txt`, `.avro`). |
| `--cloud-storage-max-bytes=BYTES` | Max bytes per file before flush. |
| `--cloud-storage-max-duration=DURATION` | Max time before flush (`1m`–`10m`). |
| `--cloud-storage-output-format=text\|avro` | Output encoding (default `text`). |
| `--cloud-storage-write-metadata` | Include message metadata (Avro format only). |
| `--cloud-storage-file-datetime-format=FORMAT` | Custom datetime pattern in filenames. |

The Pub/Sub service agent needs `roles/storage.objectAdmin` (or
create+get permissions) on the bucket.

### 2.5 List, describe, and update subscriptions

```
gcloud pubsub subscriptions list \
  --project=PROJECT_ID
```

```
gcloud pubsub subscriptions describe SUBSCRIPTION_ID \
  --project=PROJECT_ID
```

Update the ack deadline / retention / dead-letter policy in place:

```
gcloud pubsub subscriptions update SUBSCRIPTION_ID \
  --ack-deadline=120 \
  --message-retention-duration=2d \
  --project=PROJECT_ID \
  --quiet
```

Attach or change a dead-letter policy after creation:

```
gcloud pubsub subscriptions update SUBSCRIPTION_ID \
  --dead-letter-topic=DEAD_LETTER_TOPIC_ID \
  --max-delivery-attempts=10 \
  --project=PROJECT_ID \
  --quiet
```

Remove a dead-letter policy:

```
gcloud pubsub subscriptions update SUBSCRIPTION_ID \
  --clear-dead-letter-policy \
  --project=PROJECT_ID \
  --quiet
```

### 2.6 Pull messages manually

Pull and immediately auto-acknowledge (consumes the messages):

```
gcloud pubsub subscriptions pull SUBSCRIPTION_ID \
  --auto-ack \
  --limit=10 \
  --project=PROJECT_ID
```

Pull for inspection WITHOUT acking (messages are redelivered after the ack
deadline). Omitting `--auto-ack` leaves the messages unacked:

```
gcloud pubsub subscriptions pull SUBSCRIPTION_ID \
  --limit=10 \
  --project=PROJECT_ID
```

Show the ack IDs so you can ack selectively (see §2.7):

```
gcloud pubsub subscriptions pull SUBSCRIPTION_ID \
  --limit=10 \
  --format="table(message.data.decode(base64), ackId)" \
  --project=PROJECT_ID
```

### 2.7 Acknowledge messages manually

After a non-auto-ack pull, ack the IDs you successfully processed. `--ack-ids`
takes one ID or a comma-separated list:

```
gcloud pubsub subscriptions ack SUBSCRIPTION_ID \
  --ack-ids=ACK_ID_1,ACK_ID_2 \
  --project=PROJECT_ID
```

Extend the ack deadline for in-flight messages (give yourself more time before
redelivery) by modifying the ack deadline:

```
gcloud pubsub subscriptions modify-message-ack-deadline SUBSCRIPTION_ID \
  --ack-ids=ACK_ID_1 \
  --ack-deadline=120 \
  --project=PROJECT_ID
```

### 2.8 Snapshots (for replay)

A snapshot captures the ack state of a subscription so you can later seek back
to it. Snapshots retain the backlog up to the source topic's retention.

Create a snapshot from a subscription:

```
gcloud pubsub snapshots create SNAPSHOT_ID \
  --subscription=SUBSCRIPTION_ID \
  --project=PROJECT_ID \
  --quiet
```

List and describe snapshots:

```
gcloud pubsub snapshots list \
  --project=PROJECT_ID

gcloud pubsub snapshots describe SNAPSHOT_ID \
  --project=PROJECT_ID
```

Delete a snapshot:

```
gcloud pubsub snapshots delete SNAPSHOT_ID \
  --project=PROJECT_ID \
  --quiet
```

### 2.9 Seek operations (replay / purge — destructive)

> [!CAUTION]
> Seeking rewrites the subscription's ack state. Seeking forward (to "now" or a
> recent timestamp) discards the current backlog permanently. This is on the
> skill denylist — get recorded approval first.

Seek to a snapshot (restore the ack state captured earlier):

```
gcloud pubsub subscriptions seek SUBSCRIPTION_ID \
  --snapshot=SNAPSHOT_ID \
  --project=PROJECT_ID \
  --quiet
```

If the snapshot is in another project, add `--snapshot-project=SNAPSHOT_PROJECT_ID`.

Seek to a timestamp (RFC 3339). Messages published/acked relative to this time
are re-presented or skipped accordingly:

```
gcloud pubsub subscriptions seek SUBSCRIPTION_ID \
  --time=2026-06-04T00:00:00Z \
  --project=PROJECT_ID \
  --quiet
```

Purge the backlog by seeking to the current time (discards all currently
outstanding messages):

```
gcloud pubsub subscriptions seek SUBSCRIPTION_ID \
  --time=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --project=PROJECT_ID \
  --quiet
```

### 2.10 Detach / delete a subscription (prohibited without approval)

Detach a subscription from its topic (stops delivery immediately):

```
gcloud pubsub topics detach-subscription SUBSCRIPTION_ID \
  --project=PROJECT_ID \
  --quiet
```

Delete a subscription (drops all unacked messages):

```
gcloud pubsub subscriptions delete SUBSCRIPTION_ID \
  --project=PROJECT_ID \
  --quiet
```

---

## 3. Schemas management

Schema types in `gcloud` are `avro` and `protocol-buffer`. Definitions may be
supplied inline with `--definition='...'` or from a file with
`--definition-file=PATH`.

### 3.1 Create an Avro schema (inline)

```
gcloud pubsub schemas create SCHEMA_ID \
  --type=avro \
  --definition='{"type":"record","name":"Order","fields":[{"name":"order_id","type":"string"},{"name":"amount","type":"double"}]}' \
  --project=PROJECT_ID \
  --quiet
```

### 3.2 Create an Avro schema (from a file)

```
gcloud pubsub schemas create SCHEMA_ID \
  --type=avro \
  --definition-file=./schemas/order.avsc \
  --project=PROJECT_ID \
  --quiet
```

### 3.3 Create a Protocol Buffer schema (inline)

```
gcloud pubsub schemas create SCHEMA_ID \
  --type=protocol-buffer \
  --definition='syntax = "proto3"; message Order { string order_id = 1; double amount = 2; }' \
  --project=PROJECT_ID \
  --quiet
```

### 3.4 Create a Protocol Buffer schema (from a file)

```
gcloud pubsub schemas create SCHEMA_ID \
  --type=protocol-buffer \
  --definition-file=./schemas/order.proto \
  --project=PROJECT_ID \
  --quiet
```

### 3.5 List and describe schemas

```
gcloud pubsub schemas list \
  --project=PROJECT_ID

gcloud pubsub schemas describe SCHEMA_ID \
  --project=PROJECT_ID
```

List revisions of a schema:

```
gcloud pubsub schemas list-revisions SCHEMA_ID \
  --project=PROJECT_ID
```

### 3.6 Validate a schema definition or a sample message

Validate that a definition is well-formed before creating the schema:

```
gcloud pubsub schemas validate-schema \
  --type=avro \
  --definition-file=./schemas/order.avsc \
  --project=PROJECT_ID
```

Validate a sample message against an existing schema + encoding:

```
gcloud pubsub schemas validate-message \
  --schema-name=SCHEMA_ID \
  --message-encoding=json \
  --message='{"order_id":"A-1","amount":9.99}' \
  --project=PROJECT_ID
```

Validate against an as-yet-uncreated definition:

```
gcloud pubsub schemas validate-message \
  --type=avro \
  --definition-file=./schemas/order.avsc \
  --message-encoding=binary \
  --message-file=./samples/order.bin \
  --project=PROJECT_ID
```

### 3.7 Commit a new schema revision

Schema evolution is done by committing a new revision (the existing revisions
are retained):

```
gcloud pubsub schemas commit SCHEMA_ID \
  --type=avro \
  --definition-file=./schemas/order-v2.avsc \
  --project=PROJECT_ID \
  --quiet
```

### 3.8 Associate a schema with a topic

A schema is bound at topic-creation time (you cannot add a schema to an existing
topic via `topics update`). Create the topic with the schema and an encoding:

```
gcloud pubsub topics create TOPIC_ID \
  --schema=SCHEMA_ID \
  --message-encoding=json \
  --project=PROJECT_ID \
  --quiet
```

Bind to a specific revision range:

```
gcloud pubsub topics create TOPIC_ID \
  --schema=SCHEMA_ID \
  --message-encoding=binary \
  --first-revision-id=FIRST_REVISION_ID \
  --last-revision-id=LAST_REVISION_ID \
  --project=PROJECT_ID \
  --quiet
```

### 3.9 Delete a schema or schema revision (prohibited without approval)

Deleting a schema can invalidate in-flight producers — denylisted.

```
gcloud pubsub schemas delete SCHEMA_ID \
  --project=PROJECT_ID \
  --quiet
```

Delete a single revision:

```
gcloud pubsub schemas delete-revision SCHEMA_ID@REVISION_ID \
  --project=PROJECT_ID \
  --quiet
```

---

## 4. Quick reference / cheat sheet

### Topics

| Task | Command template |
| --- | --- |
| Create topic | `gcloud pubsub topics create TOPIC_ID --project=PROJECT_ID` |
| Create with retention | `gcloud pubsub topics create TOPIC_ID --message-retention-duration=7d --project=PROJECT_ID` |
| Create with schema | `gcloud pubsub topics create TOPIC_ID --schema=SCHEMA_ID --message-encoding=json --project=PROJECT_ID` |
| Create with CMEK | `gcloud pubsub topics create TOPIC_ID --topic-encryption-key=projects/PROJECT_ID/locations/LOCATION/keyRings/KEYRING_ID/cryptoKeys/KEY_ID --project=PROJECT_ID` |
| List topics | `gcloud pubsub topics list --project=PROJECT_ID` |
| Describe topic | `gcloud pubsub topics describe TOPIC_ID --project=PROJECT_ID` |
| List attached subs | `gcloud pubsub topics list-subscriptions TOPIC_ID --project=PROJECT_ID` |
| Update topic | `gcloud pubsub topics update TOPIC_ID --message-retention-duration=14d --project=PROJECT_ID` |
| Delete topic ⚠️ | `gcloud pubsub topics delete TOPIC_ID --project=PROJECT_ID` |
| Publish message | `gcloud pubsub topics publish TOPIC_ID --message="BODY" --project=PROJECT_ID` |
| Publish w/ attributes | `gcloud pubsub topics publish TOPIC_ID --message="BODY" --attribute=k1=v1,k2=v2 --project=PROJECT_ID` |
| Publish w/ ordering key | `gcloud pubsub topics publish TOPIC_ID --message="BODY" --ordering-key=KEY --project=PROJECT_ID` |

### Subscriptions

| Task | Command template |
| --- | --- |
| Create pull | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=TOPIC_ID --ack-deadline=60 --project=PROJECT_ID` |
| Create push | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=TOPIC_ID --push-endpoint=ENDPOINT --project=PROJECT_ID` |
| Create authenticated push | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=TOPIC_ID --push-endpoint=ENDPOINT --push-auth-service-account=SA_EMAIL --project=PROJECT_ID` |
| Create BigQuery | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=TOPIC_ID --bigquery-table=PROJECT_ID:DATASET_ID.TABLE_ID --use-table-schema --project=PROJECT_ID` |
| Create Cloud Storage | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=TOPIC_ID --cloud-storage-bucket=BUCKET_NAME --cloud-storage-max-duration=300s --project=PROJECT_ID` |
| Create w/ dead-letter | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=TOPIC_ID --dead-letter-topic=DEAD_LETTER_TOPIC_ID --max-delivery-attempts=5 --project=PROJECT_ID` |
| Create w/ ordering | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=TOPIC_ID --enable-message-ordering --project=PROJECT_ID` |
| List subs | `gcloud pubsub subscriptions list --project=PROJECT_ID` |
| Describe sub | `gcloud pubsub subscriptions describe SUBSCRIPTION_ID --project=PROJECT_ID` |
| Update ack deadline | `gcloud pubsub subscriptions update SUBSCRIPTION_ID --ack-deadline=120 --project=PROJECT_ID` |
| Pull (auto-ack) | `gcloud pubsub subscriptions pull SUBSCRIPTION_ID --auto-ack --limit=10 --project=PROJECT_ID` |
| Pull (no ack) | `gcloud pubsub subscriptions pull SUBSCRIPTION_ID --limit=10 --project=PROJECT_ID` |
| Acknowledge | `gcloud pubsub subscriptions ack SUBSCRIPTION_ID --ack-ids=ACK_ID_1,ACK_ID_2 --project=PROJECT_ID` |
| Modify ack deadline | `gcloud pubsub subscriptions modify-message-ack-deadline SUBSCRIPTION_ID --ack-ids=ACK_ID --ack-deadline=120 --project=PROJECT_ID` |
| Seek to snapshot ⚠️ | `gcloud pubsub subscriptions seek SUBSCRIPTION_ID --snapshot=SNAPSHOT_ID --project=PROJECT_ID` |
| Seek to timestamp ⚠️ | `gcloud pubsub subscriptions seek SUBSCRIPTION_ID --time=2026-06-04T00:00:00Z --project=PROJECT_ID` |
| Detach sub ⚠️ | `gcloud pubsub topics detach-subscription SUBSCRIPTION_ID --project=PROJECT_ID` |
| Delete sub ⚠️ | `gcloud pubsub subscriptions delete SUBSCRIPTION_ID --project=PROJECT_ID` |

### Snapshots

| Task | Command template |
| --- | --- |
| Create snapshot | `gcloud pubsub snapshots create SNAPSHOT_ID --subscription=SUBSCRIPTION_ID --project=PROJECT_ID` |
| List snapshots | `gcloud pubsub snapshots list --project=PROJECT_ID` |
| Describe snapshot | `gcloud pubsub snapshots describe SNAPSHOT_ID --project=PROJECT_ID` |
| Delete snapshot | `gcloud pubsub snapshots delete SNAPSHOT_ID --project=PROJECT_ID` |

### Schemas

| Task | Command template |
| --- | --- |
| Create Avro (inline) | `gcloud pubsub schemas create SCHEMA_ID --type=avro --definition='{...}' --project=PROJECT_ID` |
| Create Avro (file) | `gcloud pubsub schemas create SCHEMA_ID --type=avro --definition-file=PATH --project=PROJECT_ID` |
| Create Protobuf (inline) | `gcloud pubsub schemas create SCHEMA_ID --type=protocol-buffer --definition='syntax = "proto3"; ...' --project=PROJECT_ID` |
| Create Protobuf (file) | `gcloud pubsub schemas create SCHEMA_ID --type=protocol-buffer --definition-file=PATH --project=PROJECT_ID` |
| List schemas | `gcloud pubsub schemas list --project=PROJECT_ID` |
| Describe schema | `gcloud pubsub schemas describe SCHEMA_ID --project=PROJECT_ID` |
| List revisions | `gcloud pubsub schemas list-revisions SCHEMA_ID --project=PROJECT_ID` |
| Validate definition | `gcloud pubsub schemas validate-schema --type=avro --definition-file=PATH --project=PROJECT_ID` |
| Validate message | `gcloud pubsub schemas validate-message --schema-name=SCHEMA_ID --message-encoding=json --message='{...}' --project=PROJECT_ID` |
| Commit revision | `gcloud pubsub schemas commit SCHEMA_ID --type=avro --definition-file=PATH --project=PROJECT_ID` |
| Associate w/ topic | `gcloud pubsub topics create TOPIC_ID --schema=SCHEMA_ID --message-encoding=json --project=PROJECT_ID` |
| Delete schema ⚠️ | `gcloud pubsub schemas delete SCHEMA_ID --project=PROJECT_ID` |

⚠️ = irreversible / on the skill denylist; requires recorded human approval.

---

## 5. Output formatting recipes

Decode base64 message data when pulling:

```
gcloud pubsub subscriptions pull SUBSCRIPTION_ID \
  --limit=10 \
  --format="table(message.data.decode(base64), message.attributes, ackId)" \
  --project=PROJECT_ID
```

Plain list of topic names:

```
gcloud pubsub topics list \
  --format="value(name.basename())" \
  --project=PROJECT_ID
```

JSON output for piping into tooling (use sparingly; respect data-reduction):

```
gcloud pubsub subscriptions describe SUBSCRIPTION_ID \
  --format=json \
  --project=PROJECT_ID
```

Count subscriptions on a topic:

```
gcloud pubsub topics list-subscriptions TOPIC_ID \
  --format="value(name)" \
  --project=PROJECT_ID
```
