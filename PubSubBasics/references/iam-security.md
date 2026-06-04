# Pub/Sub IAM & Security Reference

Detailed IAM role guidance, least-privilege binding patterns, cross-project
access, dead-letter permissions, authenticated push delivery, and
customer-managed encryption for Google Cloud Pub/Sub. Every command uses CAPS
placeholders (`PROJECT_ID`, `TOPIC_ID`, `SUBSCRIPTION_ID`, …) — replace them
with concrete values before running. Commands scope the project explicitly with
`--project=PROJECT_ID` and run non-interactively with `--quiet` where a prompt
would otherwise appear.

> [!CAUTION]
> IAM changes can silently cut off access for production services or grant
> unintended access. Adding, removing, or replacing `roles/pubsub.admin`,
> `roles/pubsub.publisher`, or `roles/pubsub.subscriber` bindings on production
> resources — and any `set-iam-policy` that replaces an entire policy — is on
> the skill denylist. Get recorded human approval before mutating production
> IAM. See the parent [`SKILL.md`](../SKILL.md) safety section.

## Least-privilege principles

Grant the **minimum** role required for a principal to do its job, scoped to the
**narrowest resource** possible. In order of preference:

1. **Resource-level bindings over project-level.** Bind a role on a single
   topic or subscription (`gcloud pubsub topics add-iam-policy-binding`) rather
   than on the whole project (`gcloud projects add-iam-policy-binding`). A
   producer that publishes to one topic should not hold project-wide publish
   rights.
2. **Granular roles over broad roles.** Prefer `roles/pubsub.publisher` or
   `roles/pubsub.subscriber` over `roles/pubsub.editor`; prefer
   `roles/pubsub.editor` over `roles/pubsub.admin`. Reserve `roles/pubsub.admin`
   for provisioning identities only.
3. **Dedicated service accounts over shared or user identities.** Give each
   workload its own service account so permissions can be audited and revoked
   independently.
4. **No primitive roles.** Never use the legacy project primitive roles
   (`roles/owner`, `roles/editor`, `roles/viewer`) to grant Pub/Sub access; they
   are far broader than any task requires.

### Where to bind a role

| Scope | Command | Use when |
| --- | --- | --- |
| Project | `gcloud projects add-iam-policy-binding PROJECT_ID` | The principal legitimately needs the role across all Pub/Sub resources (e.g. a provisioning admin, or the Pub/Sub service agent for DLQ/CMEK). |
| Topic | `gcloud pubsub topics add-iam-policy-binding TOPIC_ID` | A producer needs to publish to exactly one topic, or the service agent needs to publish to one dead-letter topic. |
| Subscription | `gcloud pubsub subscriptions add-iam-policy-binding SUBSCRIPTION_ID` | A consumer needs to read from exactly one subscription. |

Resource-level bindings are strongly preferred. The project-level template is
shown throughout this guide because the task requested it, but a comment marks
the resource-level equivalent wherever it is the safer choice.

---

## 1. Standard IAM roles

The following are the curated (predefined) Pub/Sub roles. The permission lists
are the core permissions each role carries; predefined roles may include
additional read permissions (`*.get`, `*.list`) for the resources they manage.

### 1.1 `roles/pubsub.viewer` — Viewer

Read-only access to view resources and their configuration. Grant for
inspection, auditing, and dashboards. Cannot read message **data**.

| Permission | Allows |
| --- | --- |
| `pubsub.topics.get` | View a topic's configuration. |
| `pubsub.topics.list` | List topics in the project. |
| `pubsub.subscriptions.get` | View a subscription's configuration. |
| `pubsub.subscriptions.list` | List subscriptions in the project. |
| `pubsub.schemas.get` | View a schema. |
| `pubsub.schemas.list` | List schemas. |
| `pubsub.snapshots.get` / `pubsub.snapshots.list` | View / list snapshots. |

Grant at project level:

```
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="MEMBER" \
  --role="roles/pubsub.viewer" \
  --quiet
```

### 1.2 `roles/pubsub.publisher` — Publisher

Publish messages to topics. Grant to **producer** workloads. Carries no read of
subscriptions and cannot create or delete resources.

| Permission | Allows |
| --- | --- |
| `pubsub.topics.publish` | Publish messages to a topic. |

Least-privilege (resource-level — preferred for producers):

```
gcloud pubsub topics add-iam-policy-binding TOPIC_ID \
  --member="MEMBER" \
  --role="roles/pubsub.publisher" \
  --project=PROJECT_ID \
  --quiet
```

Project-level equivalent (broader — only if the producer publishes to many
topics):

```
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="MEMBER" \
  --role="roles/pubsub.publisher" \
  --quiet
```

### 1.3 `roles/pubsub.subscriber` — Subscriber

Consume and acknowledge messages from subscriptions, and attach a subscription
to a topic. Grant to **consumer** workloads. This is also the role the Pub/Sub
service agent needs on the source subscription for dead-lettering (see §3).

| Permission | Allows |
| --- | --- |
| `pubsub.subscriptions.consume` | Pull and acknowledge messages from a subscription. |
| `pubsub.topics.attachSubscription` | Attach a new subscription to a topic. |
| `pubsub.snapshots.seek` | Seek a subscription to a snapshot. |

Least-privilege (resource-level — preferred for consumers):

```
gcloud pubsub subscriptions add-iam-policy-binding SUBSCRIPTION_ID \
  --member="MEMBER" \
  --role="roles/pubsub.subscriber" \
  --project=PROJECT_ID \
  --quiet
```

> Note: `pubsub.topics.attachSubscription` is checked on the **topic**, not the
> subscription. To create a subscription against a topic, the creating identity
> needs subscriber (or editor/admin) permission that includes
> `attachSubscription` on the topic, plus permission to create the subscription
> resource.

Project-level equivalent:

```
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="MEMBER" \
  --role="roles/pubsub.subscriber" \
  --quiet
```

### 1.4 `roles/pubsub.editor` — Editor

Full create/update/delete on topics, subscriptions, schemas, and snapshots, plus
publish and consume — but **not** IAM policy management. Grant to operators who
manage the messaging plane but should not alter access control. Includes all
permissions in `roles/pubsub.viewer`, `roles/pubsub.publisher`, and
`roles/pubsub.subscriber`, plus:

| Permission | Allows |
| --- | --- |
| `pubsub.topics.create` / `pubsub.topics.update` / `pubsub.topics.delete` | Manage topics. |
| `pubsub.subscriptions.create` / `.update` / `.delete` | Manage subscriptions. |
| `pubsub.schemas.create` / `.delete` / `.commit` / `.validate` | Manage schemas. |
| `pubsub.snapshots.create` / `.update` / `.delete` | Manage snapshots. |
| `pubsub.topics.detachSubscription` | Detach a subscription from a topic. |

It does **not** include `pubsub.*.getIamPolicy` / `setIamPolicy`.

```
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="MEMBER" \
  --role="roles/pubsub.editor" \
  --quiet
```

### 1.5 `roles/pubsub.admin` — Admin

Everything in `roles/pubsub.editor` **plus** IAM policy management on Pub/Sub
resources. Restrict to a small set of provisioning identities. Includes:

| Permission | Allows |
| --- | --- |
| (all of `roles/pubsub.editor`) | Manage all resources, publish, consume. |
| `pubsub.topics.getIamPolicy` / `setIamPolicy` | Read/replace IAM on topics. |
| `pubsub.subscriptions.getIamPolicy` / `setIamPolicy` | Read/replace IAM on subscriptions. |
| `pubsub.schemas.getIamPolicy` / `setIamPolicy` | Read/replace IAM on schemas. |
| `pubsub.snapshots.getIamPolicy` / `setIamPolicy` | Read/replace IAM on snapshots. |

```
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="MEMBER" \
  --role="roles/pubsub.admin" \
  --quiet
```

### 1.6 Role selection summary

| If the principal needs to… | Grant | Bind at |
| --- | --- | --- |
| Publish to a topic | `roles/pubsub.publisher` | Topic |
| Consume from a subscription | `roles/pubsub.subscriber` | Subscription |
| Inspect config only | `roles/pubsub.viewer` | Project (or resource) |
| Create/manage resources, no IAM | `roles/pubsub.editor` | Project |
| Manage resources **and** IAM | `roles/pubsub.admin` | Project (restrict) |

### 1.7 The `--member` (MEMBER) format

Replace `MEMBER` with one of the following identity formats:

| Identity type | `--member` value |
| --- | --- |
| Service account | `serviceAccount:NAME@PROJECT_ID.iam.gserviceaccount.com` |
| Google account (user) | `user:alice@example.com` |
| Google group | `group:team@example.com` |
| Workspace / Cloud Identity domain | `domain:example.com` |
| Pub/Sub service agent | `serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com` |

### 1.8 Inspecting and removing bindings

Always inspect before and after a change. View the current policy on a resource:

```
gcloud pubsub topics get-iam-policy TOPIC_ID \
  --project=PROJECT_ID
```

```
gcloud pubsub subscriptions get-iam-policy SUBSCRIPTION_ID \
  --project=PROJECT_ID
```

Remove a single binding (least-disruptive revocation — prefer this over
`set-iam-policy`, which replaces the entire policy):

```
gcloud pubsub topics remove-iam-policy-binding TOPIC_ID \
  --member="MEMBER" \
  --role="roles/pubsub.publisher" \
  --project=PROJECT_ID \
  --quiet
```

```
gcloud projects remove-iam-policy-binding PROJECT_ID \
  --member="MEMBER" \
  --role="roles/pubsub.publisher" \
  --quiet
```

> [!CAUTION]
> Avoid `set-iam-policy` for routine changes. It overwrites the **whole** policy
> and will silently drop any binding not present in the supplied file, including
> ones added by other teams or by Google-managed automation. Use the
> `add-iam-policy-binding` / `remove-iam-policy-binding` verbs, which mutate a
> single binding atomically.

---

## 2. Cross-project Pub/Sub access

Topics and subscriptions can live in different projects: a producer project owns
the topic, and a consumer project owns a subscription that reads from that
topic. IAM is what bridges the two. The principle is unchanged — grant the
consuming identity the needed role **on the resource in the other project**.

Throughout this section:

- `TOPIC_PROJECT_ID` — project that owns the topic.
- `SUB_PROJECT_ID` — project that owns the subscription / consumer.
- A subscription always lives in the project where it is created; it can point
  at a topic in another project via the fully-qualified topic path.

### 2.1 Create a subscription in one project against a topic in another

The identity creating the subscription needs `pubsub.topics.attachSubscription`
on the **topic** (granted via `roles/pubsub.subscriber`, `editor`, or `admin`).
Grant it on the topic in the topic's project:

```
gcloud pubsub topics add-iam-policy-binding TOPIC_ID \
  --member="serviceAccount:CREATOR_SA@SUB_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/pubsub.subscriber" \
  --project=TOPIC_PROJECT_ID \
  --quiet
```

Then create the subscription in the subscription's project, referencing the
topic by its **full resource path**:

```
gcloud pubsub subscriptions create SUBSCRIPTION_ID \
  --topic=projects/TOPIC_PROJECT_ID/topics/TOPIC_ID \
  --ack-deadline=60 \
  --project=SUB_PROJECT_ID \
  --quiet
```

### 2.2 Grant a producer in project A publish rights to a topic in project B

Bind publisher on the topic, naming the producer's service account from the
other project:

```
gcloud pubsub topics add-iam-policy-binding TOPIC_ID \
  --member="serviceAccount:PRODUCER_SA@PRODUCER_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher" \
  --project=TOPIC_PROJECT_ID \
  --quiet
```

### 2.3 Grant a consumer in project A consume rights on a subscription in project B

Bind subscriber on the subscription, naming the consumer's service account from
the other project:

```
gcloud pubsub subscriptions add-iam-policy-binding SUBSCRIPTION_ID \
  --member="serviceAccount:CONSUMER_SA@CONSUMER_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/pubsub.subscriber" \
  --project=SUB_PROJECT_ID \
  --quiet
```

### 2.4 Cross-project notes

- **Two service agents may be involved.** Export-style subscriptions (BigQuery,
  Cloud Storage, dead-letter) act through the **subscription project's** Pub/Sub
  service agent (`service-SUB_PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com`).
  Grant that agent the relevant role on the destination resource, even if the
  destination is in yet another project.
- **Each resource's project owns its IAM.** You must run the binding command
  with `--project` set to the project that **contains the resource** being
  bound, not the project of the member.
- **Message storage policy / org policy** can restrict cross-region storage;
  cross-project does not by itself change residency, but confirm any
  organization policy constraints (`constraints/gcp.resourceLocations`).

---

## 3. Dead Letter Queue (DLQ) permissions

When a subscription has a dead-letter policy, Pub/Sub forwards undeliverable
messages to the dead-letter topic **as the project's Pub/Sub service agent**,
and it acknowledges the original messages on the source subscription as that same
agent. The service agent therefore needs two grants:

1. `roles/pubsub.publisher` on the **dead-letter topic** — to forward messages.
2. `roles/pubsub.subscriber` on the **source subscription** — to acknowledge the
   delivered messages.

Without both, dead-lettering silently fails and poison messages keep redelivering.

### 3.1 Identify the service agent

The Pub/Sub service agent for a project is:

```
service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com
```

Look up the numeric `PROJECT_NUMBER`:

```
gcloud projects describe PROJECT_ID \
  --format="value(projectNumber)"
```

For cross-project dead-lettering, the relevant agent is the one belonging to the
**project that owns the source subscription**.

### 3.2 Grant publish on the dead-letter topic

Resource-level (preferred):

```
gcloud pubsub topics add-iam-policy-binding DEAD_LETTER_TOPIC_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher" \
  --project=PROJECT_ID \
  --quiet
```

Project-level equivalent (broader):

```
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher" \
  --quiet
```

### 3.3 Grant subscribe on the source subscription

Resource-level (preferred):

```
gcloud pubsub subscriptions add-iam-policy-binding SUBSCRIPTION_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/pubsub.subscriber" \
  --project=PROJECT_ID \
  --quiet
```

Project-level equivalent (broader):

```
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/pubsub.subscriber" \
  --quiet
```

### 3.4 Attach the dead-letter policy

After the two grants exist, attach (or create with) the dead-letter policy:

```
gcloud pubsub subscriptions update SUBSCRIPTION_ID \
  --dead-letter-topic=DEAD_LETTER_TOPIC_ID \
  --max-delivery-attempts=5 \
  --project=PROJECT_ID \
  --quiet
```

If the dead-letter topic is in another project, reference it fully and add the
project flag:

```
gcloud pubsub subscriptions update SUBSCRIPTION_ID \
  --dead-letter-topic=DEAD_LETTER_TOPIC_ID \
  --dead-letter-topic-project=DLT_PROJECT_ID \
  --max-delivery-attempts=5 \
  --project=PROJECT_ID \
  --quiet
```

### 3.5 Recommended: a dedicated DLQ consumer

Create a separate subscription on the dead-letter topic so operators can inspect
and reprocess poison messages, and grant the on-call/operator identity
subscriber on **that** subscription only:

```
gcloud pubsub subscriptions create DEAD_LETTER_TOPIC_ID-sub \
  --topic=DEAD_LETTER_TOPIC_ID \
  --ack-deadline=60 \
  --project=PROJECT_ID \
  --quiet
```

```
gcloud pubsub subscriptions add-iam-policy-binding DEAD_LETTER_TOPIC_ID-sub \
  --member="MEMBER" \
  --role="roles/pubsub.subscriber" \
  --project=PROJECT_ID \
  --quiet
```

---

## 4. Push subscription authentication

For push delivery to a private or access-controlled endpoint (e.g. an
authenticated Cloud Run service, Cloud Functions function, or any endpoint that
validates a bearer token), configure Pub/Sub to attach a signed **OIDC token**
to each push request. Pub/Sub generates the token as a designated push **service
account**, and the endpoint verifies it.

### 4.1 Prepare a dedicated push service account

Create an identity whose sole purpose is signing push tokens:

```
gcloud iam service-accounts create pubsub-push \
  --display-name="Pub/Sub push auth" \
  --project=PROJECT_ID \
  --quiet
```

This yields `pubsub-push@PROJECT_ID.iam.gserviceaccount.com`
(`PUSH_SERVICE_ACCOUNT_EMAIL`).

### 4.2 Let the Pub/Sub service agent mint tokens as the push SA

Pub/Sub's own service agent must be able to create OIDC tokens for the push
service account. Grant the service agent the Service Account Token Creator role
**on the push service account**:

```
gcloud iam service-accounts add-iam-policy-binding PUSH_SERVICE_ACCOUNT_EMAIL \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project=PROJECT_ID \
  --quiet
```

> This grant is created automatically the first time you configure an
> authenticated push subscription through the Console, but must be added
> explicitly when configuring via CLI/IaC.

### 4.3 Grant the push SA permission to invoke the endpoint

The push service account is the caller the endpoint sees. Grant it the invoker
role on the target service.

Cloud Run:

```
gcloud run services add-iam-policy-binding SERVICE_NAME \
  --member="serviceAccount:PUSH_SERVICE_ACCOUNT_EMAIL" \
  --role="roles/run.invoker" \
  --region=REGION \
  --project=PROJECT_ID \
  --quiet
```

Cloud Functions (2nd gen runs on Cloud Run — use `run.invoker` as above; 1st
gen uses `cloudfunctions.invoker`):

```
gcloud functions add-iam-policy-binding FUNCTION_NAME \
  --member="serviceAccount:PUSH_SERVICE_ACCOUNT_EMAIL" \
  --role="roles/cloudfunctions.invoker" \
  --region=REGION \
  --project=PROJECT_ID \
  --quiet
```

### 4.4 The configuring identity must be able to act as the push SA

The human or automation identity that **creates** the push subscription needs
`roles/iam.serviceAccountUser` on the push service account, otherwise the create
call is rejected:

```
gcloud iam service-accounts add-iam-policy-binding PUSH_SERVICE_ACCOUNT_EMAIL \
  --member="MEMBER" \
  --role="roles/iam.serviceAccountUser" \
  --project=PROJECT_ID \
  --quiet
```

### 4.5 Create the authenticated push subscription with OIDC

Attach the push auth service account so Pub/Sub signs each request; set the
audience to a value the endpoint expects (commonly the endpoint URL):

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

Update an existing push subscription to add or rotate the auth SA / audience:

```
gcloud pubsub subscriptions update SUBSCRIPTION_ID \
  --push-endpoint=ENDPOINT \
  --push-auth-service-account=PUSH_SERVICE_ACCOUNT_EMAIL \
  --push-auth-token-audience=AUDIENCE \
  --project=PROJECT_ID \
  --quiet
```

### 4.6 Validate the push endpoint

- **Token verification at the endpoint.** The endpoint should verify the JWT in
  the `Authorization: Bearer …` header: confirm the signature against Google's
  public certs, that `iss` is `https://accounts.google.com`, that `email` equals
  `PUSH_SERVICE_ACCOUNT_EMAIL` and `email_verified` is true, that `aud` matches
  the configured `AUDIENCE`, and that the token is unexpired.
- **HTTPS only.** Push endpoints must be HTTPS with a valid certificate.
- **Domain ownership.** For arbitrary (non-Google) HTTPS endpoints, the domain
  must be verified in Search Console and registered for the project before
  Pub/Sub will push to it. Google-managed endpoints (Cloud Run, Functions, App
  Engine) do not require this.
- **Confirm config took effect:**

  ```
  gcloud pubsub subscriptions describe SUBSCRIPTION_ID \
    --format="value(pushConfig.pushEndpoint, pushConfig.oidcToken.serviceAccountEmail, pushConfig.oidcToken.audience)" \
    --project=PROJECT_ID
  ```

- **End-to-end check.** Publish a test message and confirm the endpoint receives
  an authenticated request and returns a success status (`102/200/201/202/204`),
  which acks the message:

  ```
  gcloud pubsub topics publish TOPIC_ID \
    --message="push-auth-test" \
    --project=PROJECT_ID
  ```

---

## 5. Encryption & security

### 5.1 Encryption at rest (default)

Pub/Sub encrypts all message data at rest by default with Google-managed keys.
No configuration is required. Use customer-managed keys (CMEK) when you need
control over the key lifecycle, the ability to revoke access by disabling the
key, or to satisfy compliance requirements.

### 5.2 Customer-Managed Encryption Keys (CMEK) with Cloud KMS

A topic can be configured with a Cloud KMS key; Pub/Sub uses it to encrypt
message data before persisting it. The Pub/Sub **service agent** must hold
`roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key.

**Step 1 — create a key ring and key** (if one does not exist):

```
gcloud kms keyrings create KEYRING_ID \
  --location=LOCATION \
  --project=KMS_PROJECT_ID \
  --quiet
```

```
gcloud kms keys create KEY_ID \
  --keyring=KEYRING_ID \
  --location=LOCATION \
  --purpose=encryption \
  --project=KMS_PROJECT_ID \
  --quiet
```

**Step 2 — grant the Pub/Sub service agent encrypt/decrypt on the key.** This is
a KMS-level binding, but the project-level template form is shown below as well.

Key-level (preferred — narrowest scope):

```
gcloud kms keys add-iam-policy-binding KEY_ID \
  --keyring=KEYRING_ID \
  --location=LOCATION \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --project=KMS_PROJECT_ID \
  --quiet
```

Project-level equivalent (broader — grants on every key in the KMS project, use
only if intentional):

```
gcloud projects add-iam-policy-binding KMS_PROJECT_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --quiet
```

> `PROJECT_NUMBER` is the number of the project that **owns the topic**, even
> when the key lives in a different `KMS_PROJECT_ID`.

**Step 3 — create the topic with the key** (a schema/CMEK key is set at creation
time):

```
gcloud pubsub topics create TOPIC_ID \
  --topic-encryption-key=projects/KMS_PROJECT_ID/locations/LOCATION/keyRings/KEYRING_ID/cryptoKeys/KEY_ID \
  --project=PROJECT_ID \
  --quiet
```

**Step 4 — verify the binding:**

```
gcloud pubsub topics describe TOPIC_ID \
  --format="value(kmsKeyName)" \
  --project=PROJECT_ID
```

### 5.3 Key location and revocation

- **Co-locate the key.** Use a KMS key in (or near) the same region as the
  topic's message storage to minimize latency and satisfy residency rules.
- **Revocation.** Disabling or destroying the key, or removing the service
  agent's encrypter/decrypter binding, causes Pub/Sub to stop being able to
  encrypt new messages and decrypt stored ones — publishing and delivery fail
  until access is restored. Treat key disable/destroy as a production-impacting
  action requiring approval.

### 5.4 Defense-in-depth recommendations

- **VPC Service Controls.** Place Pub/Sub inside a service perimeter to prevent
  data exfiltration to projects outside the perimeter.
- **Message storage policy.** Constrain where message data is stored for
  residency:

  ```
  gcloud pubsub topics update TOPIC_ID \
    --message-storage-policy-allowed-regions=us-central1,us-east1 \
    --project=PROJECT_ID \
    --quiet
  ```

- **Organization policy** `constraints/gcp.restrictNonCmekServices` can require
  CMEK for `pubsub.googleapis.com`, blocking creation of unencrypted topics.
- **Audit logging.** Pub/Sub Admin Activity logs are always on; enable Data
  Access logs to record `publish`/`pull`/`ack` activity for sensitive topics.
- **No keys in messages.** Never put credentials, tokens, or secrets in message
  bodies or attributes; reference them from Secret Manager instead.

---

## 6. Quick reference / cheat sheet

### Standard role grants (project scope)

| Role | Command template |
| --- | --- |
| Viewer | `gcloud projects add-iam-policy-binding PROJECT_ID --member="MEMBER" --role="roles/pubsub.viewer"` |
| Publisher | `gcloud projects add-iam-policy-binding PROJECT_ID --member="MEMBER" --role="roles/pubsub.publisher"` |
| Subscriber | `gcloud projects add-iam-policy-binding PROJECT_ID --member="MEMBER" --role="roles/pubsub.subscriber"` |
| Editor | `gcloud projects add-iam-policy-binding PROJECT_ID --member="MEMBER" --role="roles/pubsub.editor"` |
| Admin ⚠️ | `gcloud projects add-iam-policy-binding PROJECT_ID --member="MEMBER" --role="roles/pubsub.admin"` |

### Least-privilege resource-scoped grants

| Task | Command template |
| --- | --- |
| Publisher on one topic | `gcloud pubsub topics add-iam-policy-binding TOPIC_ID --member="MEMBER" --role="roles/pubsub.publisher" --project=PROJECT_ID` |
| Subscriber on one sub | `gcloud pubsub subscriptions add-iam-policy-binding SUBSCRIPTION_ID --member="MEMBER" --role="roles/pubsub.subscriber" --project=PROJECT_ID` |
| Inspect topic IAM | `gcloud pubsub topics get-iam-policy TOPIC_ID --project=PROJECT_ID` |
| Inspect sub IAM | `gcloud pubsub subscriptions get-iam-policy SUBSCRIPTION_ID --project=PROJECT_ID` |
| Remove topic binding | `gcloud pubsub topics remove-iam-policy-binding TOPIC_ID --member="MEMBER" --role="ROLE" --project=PROJECT_ID` |

### Cross-project

| Task | Command template |
| --- | --- |
| Producer (proj A) → topic (proj B) | `gcloud pubsub topics add-iam-policy-binding TOPIC_ID --member="serviceAccount:PRODUCER_SA@PRODUCER_PROJECT_ID.iam.gserviceaccount.com" --role="roles/pubsub.publisher" --project=TOPIC_PROJECT_ID` |
| Allow attach (cross-project sub) | `gcloud pubsub topics add-iam-policy-binding TOPIC_ID --member="serviceAccount:CREATOR_SA@SUB_PROJECT_ID.iam.gserviceaccount.com" --role="roles/pubsub.subscriber" --project=TOPIC_PROJECT_ID` |
| Create cross-project sub | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=projects/TOPIC_PROJECT_ID/topics/TOPIC_ID --project=SUB_PROJECT_ID` |

### Dead-letter queue

| Task | Command template |
| --- | --- |
| Service agent publish on DLT | `gcloud pubsub topics add-iam-policy-binding DEAD_LETTER_TOPIC_ID --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" --role="roles/pubsub.publisher" --project=PROJECT_ID` |
| Service agent subscribe on source | `gcloud pubsub subscriptions add-iam-policy-binding SUBSCRIPTION_ID --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" --role="roles/pubsub.subscriber" --project=PROJECT_ID` |
| Attach DLT policy | `gcloud pubsub subscriptions update SUBSCRIPTION_ID --dead-letter-topic=DEAD_LETTER_TOPIC_ID --max-delivery-attempts=5 --project=PROJECT_ID` |

### Push authentication (OIDC)

| Task | Command template |
| --- | --- |
| Service agent → token creator | `gcloud iam service-accounts add-iam-policy-binding PUSH_SERVICE_ACCOUNT_EMAIL --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" --role="roles/iam.serviceAccountTokenCreator" --project=PROJECT_ID` |
| Push SA → invoke Cloud Run | `gcloud run services add-iam-policy-binding SERVICE_NAME --member="serviceAccount:PUSH_SERVICE_ACCOUNT_EMAIL" --role="roles/run.invoker" --region=REGION --project=PROJECT_ID` |
| Configurer → act as push SA | `gcloud iam service-accounts add-iam-policy-binding PUSH_SERVICE_ACCOUNT_EMAIL --member="MEMBER" --role="roles/iam.serviceAccountUser" --project=PROJECT_ID` |
| Create authenticated push sub | `gcloud pubsub subscriptions create SUBSCRIPTION_ID --topic=TOPIC_ID --push-endpoint=ENDPOINT --push-auth-service-account=PUSH_SERVICE_ACCOUNT_EMAIL --push-auth-token-audience=AUDIENCE --project=PROJECT_ID` |

### CMEK

| Task | Command template |
| --- | --- |
| Grant agent on key | `gcloud kms keys add-iam-policy-binding KEY_ID --keyring=KEYRING_ID --location=LOCATION --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" --project=KMS_PROJECT_ID` |
| Create topic w/ CMEK | `gcloud pubsub topics create TOPIC_ID --topic-encryption-key=projects/KMS_PROJECT_ID/locations/LOCATION/keyRings/KEYRING_ID/cryptoKeys/KEY_ID --project=PROJECT_ID` |
| Verify CMEK | `gcloud pubsub topics describe TOPIC_ID --format="value(kmsKeyName)" --project=PROJECT_ID` |

⚠️ = grants broad control; treat changes to admin/critical bindings as
production-impacting and get recorded approval per the skill denylist.

---

## 7. Troubleshooting / What to do if…

### …push delivery returns 401/403 from the endpoint

1. Confirm the push subscription has an OIDC token configured:
   `gcloud pubsub subscriptions describe SUBSCRIPTION_ID --format="value(pushConfig.oidcToken.serviceAccountEmail)"`.
2. Confirm the push SA has the invoker role on the target service (§4.3).
3. Confirm the Pub/Sub service agent has
   `roles/iam.serviceAccountTokenCreator` on the push SA (§4.2).
4. Confirm the endpoint's expected `aud` matches `--push-auth-token-audience`.

### …dead-lettered messages never arrive in the DLT

1. Confirm both service-agent grants exist: publisher on the DLT (§3.2) and
   subscriber on the source subscription (§3.3).
2. Confirm `PROJECT_NUMBER` is correct and belongs to the **subscription's**
   project.
3. Confirm the dead-letter policy is attached and `--max-delivery-attempts` is
   set (§3.4).

### …publishing fails after enabling CMEK

1. Confirm the service agent holds
   `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key (§5.2 step 2).
2. Confirm the key is enabled and not scheduled for destruction.
3. Confirm the `PROJECT_NUMBER` in the binding is the topic project's number,
   even if the key lives in a different KMS project.

### …a cross-project subscription cannot be created

1. Confirm the creating identity has `roles/pubsub.subscriber` (or higher) on
   the **topic** in the topic's project (§2.1).
2. Confirm the topic is referenced by full path
   `projects/TOPIC_PROJECT_ID/topics/TOPIC_ID`.
3. Confirm `--project` on the create command is the **subscription's** project.

---

## Related references

- [`cli-usage.md`](cli-usage.md) — Full `gcloud pubsub` command reference for
  topics, subscriptions, schemas, snapshots, and output formatting.
- [`../SKILL.md`](../SKILL.md) — Skill overview, core principles, and the safety
  denylist that governs destructive and IAM-mutating operations.
</content>
</invoke>
