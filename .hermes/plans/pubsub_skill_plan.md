# GCP Pub/Sub Skill Implementation Plan

**Goal:** Create a high-quality, comprehensive, and production-ready GCP Pub/Sub Skill modeled exactly after the structure and approach used by Google in the google/skills repository.
**Architecture:** Create a self-contained skill directory containing a main `SKILL.md` and a `references/` subdirectory with highly specialized deep-dive files for CLI usage, IAM & Security, and Client Library examples.
**Tech Stack:** Google Cloud SDK (`gcloud pubsub`), Python & Node.js GCP Pub/Sub Client Libraries.
**Project Directory:** `/Users/joeshirey/Code/GitHub/HelperUtilities`

---

### Task 1: Create PubSubBasics directory and main SKILL.md

**Objective:** Create the core `PubSubBasics/SKILL.md` with standard YAML frontmatter and overview sections following the Google skills pattern.

**Files:**
- Create: `PubSubBasics/SKILL.md`

**Dispatch Prompt:**
```
Create a highly professional and comprehensive GCP Pub/Sub skill markdown file at `PubSubBasics/SKILL.md` following the google/skills structure and approach.
The file MUST have valid YAML frontmatter at the very beginning of the file (no leading blank lines, starting with ---):

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

Inside `SKILL.md`, include:
1. # GCP Pub/Sub Basics
2. An Overview of GCP Pub/Sub core concepts (Topics, Subscriptions, Push/Pull delivery, Dead Letter Topics, Schemas).
3. Detailed Prerequisites (Enabling `pubsub.googleapis.com`, installing gcloud CLI, authorization).
4. Key IAM roles needed (Pub/Sub Admin, Publisher, Subscriber, Viewer, Service Account User).
5. Step-by-step guidance on creating a standard Topic and Subscription (both Pull and Push) using the `gcloud pubsub` CLI with placeholder parameters in CAPS (e.g. TOPIC_ID, SUBSCRIPTION_ID, PROJECT_ID, ENDPOINT).
6. Essential Core Principles:
   - Explicit Command Validation (Mandatory)
   - Data Reduction (e.g., using `--limit`, Server-Side filtering, Projection)
   - Project and Location Scoping (Explicitly appending `--project=PROJECT_ID`)
   - Execution constraints (Non-interactive mode `--quiet` or `-q`, single commands, no raw shell operators)
7. Safety and Guardrails (Caution callout, Prohibited Operations Denylist like deleting topics or changing critical IAM roles without human approval).
8. A Troubleshooting / "What to do if..." section covering permission issues, subscription backlogs, unacknowledged message build-ups, and schema validation failures.
9. Reference Directory section linking to the following reference documents:
   - `references/cli-usage.md`
   - `references/iam-security.md`
   - `references/client-libraries.md`

Write the file cleanly, completely, and without any placeholders or TODOs.
```

**Scope:** write, edit
**Timeout:** 180

**Verification:**
Verify that `PubSubBasics/SKILL.md` is successfully created and has the correct frontmatter and structure.

---

### Task 2: Create references/cli-usage.md

**Objective:** Create a deep-dive `references/cli-usage.md` detailing extensive CLI commands and advanced techniques for Pub/Sub.

**Files:**
- Create: `PubSubBasics/references/cli-usage.md`

**Dispatch Prompt:**
```
Create a deep-dive CLI reference document at `PubSubBasics/references/cli-usage.md`.
The document should cover advanced CLI workflows and cheat sheets for GCP Pub/Sub, including:
1. Topics Management:
   - Creating topics (with and without schemas, message retention, and KMS keys).
   - Listing, detailing, and deleting topics.
   - Publishing messages with attributes and ordering keys.
2. Subscriptions Management:
   - Creating Pull, Push, BigQuery, and Cloud Storage subscriptions (with exact flags).
   - Setting ack deadline, message retention, and dead-letter topics during creation.
   - Pulling and acknowledging messages manually.
   - Managing subscription seek operations (seeking to a snapshot or timestamp).
3. Schemas Management:
   - Creating schemas (Avro and Protobuf) with inline and file definitions.
   - Associating schemas with topics.
4. Quick Reference / Cheat Sheet table mapping tasks to exact command templates.

Provide comprehensive examples using standard placeholders in CAPS (e.g., TOPIC_ID, SUBSCRIPTION_ID, PROJECT_ID) and make sure the `gcloud` flags are 100% accurate.
```

**Scope:** write, edit
**Timeout:** 180

**Verification:**
Verify `PubSubBasics/references/cli-usage.md` is created with high-quality content.

---

### Task 3: Create references/iam-security.md

**Objective:** Create `PubSubBasics/references/iam-security.md` detailing security, IAM, dead-letter service identity roles, and customer-managed encryption keys.

**Files:**
- Create: `PubSubBasics/references/iam-security.md`

**Dispatch Prompt:**
```
Create a dedicated IAM and Security guide at `PubSubBasics/references/iam-security.md`.
This guide must follow the highly secure "least privilege" principles of Google skills and include:
1. Standard IAM Roles: detailed breakdown of `roles/pubsub.admin`, `roles/pubsub.editor`, `roles/pubsub.publisher`, `roles/pubsub.subscriber`, and `roles/pubsub.viewer` along with exact policies.
2. Cross-Project Pub/Sub Access: detailed instructions on how to grant permissions when topics and subscriptions reside in different GCP projects.
3. Dead Letter Queue (DLQ) Permissions: clear steps on how to grant the system Pub/Sub service account (`service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com`) permission to publish to the dead-letter topic and acknowledge messages on the main subscription.
4. Push Subscription Authentication: configuring OIDC tokens, assigning custom service accounts to push subscriptions, and validating push endpoints.
5. Encryption & Security: Customer-Managed Encryption Keys (CMEK) with Cloud KMS and Pub/Sub.

Include clear `gcloud projects add-iam-policy-binding` command templates for every IAM configuration mentioned.
```

**Scope:** write, edit
**Timeout:** 180

**Verification:**
Verify `PubSubBasics/references/iam-security.md` is created with high-quality content.

---

### Task 4: Create references/client-libraries.md

**Objective:** Create `PubSubBasics/references/client-libraries.md` containing production-grade Python and Node.js code snippets for publishing and subscribing.

**Files:**
- Create: `PubSubBasics/references/client-libraries.md`

**Dispatch Prompt:**
```
Create a code-focused reference document at `PubSubBasics/references/client-libraries.md`.
The document must provide production-ready, clean, and modern code examples for Google Cloud Pub/Sub using:
1. Python Client Library (`google-cloud-pubsub`):
   - Publisher code (async publishing, custom attributes, handling publish results with futures, handling errors, custom publisher flow control).
   - Subscriber code (streaming pull, callback function, message acknowledgement, flow control to prevent memory starvation, error handling).
2. Node.js Client Library (`@google-cloud/pubsub`):
   - Publisher code (publishing with attributes, batch settings, handling promises).
   - Subscriber code (listening for messages, message options, event handlers for message/error, flow control).
3. Best Practices for Developers:
   - Reusing the publisher/subscriber client instance (avoiding instantiation on every request).
   - Handling transient errors and network retry.
   - Message ordering and deduplication strategies.

Ensure the code is robust, fully typed where appropriate, has excellent comments, and includes basic error handling.
```

**Scope:** write, edit
**Timeout:** 180

**Verification:**
Verify `PubSubBasics/references/client-libraries.md` is created with high-quality content.
