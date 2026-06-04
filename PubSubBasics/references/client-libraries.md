# Pub/Sub Client Libraries Reference

Production-ready, copy-adaptable code for publishing to and consuming from Google
Cloud Pub/Sub with the official client libraries. This document covers the
**Python** (`google-cloud-pubsub`) and **Node.js** (`@google-cloud/pubsub`)
libraries, then closes with cross-language best practices for client reuse,
transient-error handling, ordering, and deduplication.

> [!NOTE]
> When you only need to provision or inspect resources, prefer the `gcloud` CLI
> ([`cli-usage.md`](cli-usage.md)). Reach for the client libraries when an
> application must publish or consume messages as part of its runtime — they give
> you batching, flow control, streaming pull, automatic lease management, and
> retry behavior the CLI does not.

## Conventions used in this document

- `PROJECT_ID`, `TOPIC_ID`, `SUBSCRIPTION_ID` are placeholders — replace them
  with concrete values (or load from environment/config) before running.
- All examples authenticate with **Application Default Credentials (ADC)**. In
  Google environments (Cloud Run, GKE, GCE, Cloud Functions) ADC resolves to the
  attached service account automatically. Locally, run
  `gcloud auth application-default login` or set
  `GOOGLE_APPLICATION_CREDENTIALS` to a key file.
- The publishing identity needs `roles/pubsub.publisher`; the consuming identity
  needs `roles/pubsub.subscriber`. See [`iam-security.md`](iam-security.md).

### Installation

```
# Python (3.7+). Use a virtual environment.
pip install google-cloud-pubsub

# Node.js (18+).
npm install @google-cloud/pubsub
```

---

## 1. Python client library (`google-cloud-pubsub`)

The Python library exposes two primary clients: `PublisherClient` and
`SubscriberClient`. Both wrap gRPC channels and are **expensive to create** —
instantiate once per process and reuse (see [§3.1](#31-reuse-the-client-instance)).

### 1.1 Publisher — async publishing, attributes, futures, flow control

`publish()` is **asynchronous**: it returns a `concurrent.futures.Future`
immediately and batches messages in the background. Resolve the future to get
the server-assigned message ID or to surface an error. Publisher flow control
bounds how many bytes/messages may be outstanding so a fast producer cannot
exhaust memory.

```python
"""Production-ready Pub/Sub publisher.

Demonstrates batching, custom attributes, future-based result handling,
error handling, and publisher-side flow control.
"""

from __future__ import annotations

import logging
from concurrent import futures
from typing import Callable

from google.api_core import retry
from google.cloud import pubsub_v1
from google.cloud.pubsub_v1.types import (
    BatchSettings,
    LimitExceededBehavior,
    PublisherOptions,
    PublishFlowControl,
)

logger = logging.getLogger(__name__)


def build_publisher(
    project_id: str,
    topic_id: str,
) -> tuple[pubsub_v1.PublisherClient, str]:
    """Create a reusable publisher client and resolve the full topic path.

    Construct this ONCE per process and reuse it for every publish call.
    Recreating the client per request leaks gRPC channels and adds latency.
    """
    # Batch settings let the client group messages to improve throughput.
    # A batch is flushed when ANY threshold is reached, whichever comes first.
    batch_settings = BatchSettings(
        max_messages=100,          # flush after 100 messages
        max_bytes=1 * 1024 * 1024,  # ...or 1 MiB
        max_latency=0.05,          # ...or 50 ms, to bound publish latency
    )

    # Flow control bounds in-flight publishes so a burst of publish() calls
    # cannot exhaust memory. BLOCK makes publish() wait for capacity instead
    # of raising once the limits are hit.
    publisher_options = PublisherOptions(
        flow_control=PublishFlowControl(
            message_limit=1000,
            byte_limit=10 * 1024 * 1024,  # 10 MiB outstanding
            limit_exceeded_behavior=LimitExceededBehavior.BLOCK,
        ),
    )

    publisher = pubsub_v1.PublisherClient(
        batch_settings=batch_settings,
        publisher_options=publisher_options,
    )
    topic_path = publisher.topic_path(project_id, topic_id)
    return publisher, topic_path


def _make_publish_callback(
    message_label: str,
) -> Callable[[futures.Future], None]:
    """Build a done-callback that logs the message ID or the failure."""

    def _callback(future: futures.Future) -> None:
        try:
            message_id = future.result()  # raises if the publish failed
            logger.info("Published %s -> message_id=%s", message_label, message_id)
        except Exception:  # noqa: BLE001 - log and let the caller decide
            logger.exception("Failed to publish %s", message_label)

    return _callback


def publish_messages(
    publisher: pubsub_v1.PublisherClient,
    topic_path: str,
    payloads: list[dict[str, str]],
) -> None:
    """Publish a batch of messages and block until all results are known.

    Each payload is a dict with a 'body' (the message data) plus arbitrary
    string attributes used for routing, filtering, or metadata.
    """
    publish_futures: list[futures.Future] = []

    for payload in payloads:
        # Message data MUST be bytes. Attributes MUST be str -> str.
        data = payload["body"].encode("utf-8")
        attributes = {k: v for k, v in payload.items() if k != "body"}

        # publish() returns immediately; the message is batched in the
        # background. An explicit per-publish retry + timeout makes transient
        # backend errors recoverable instead of fatal.
        future = publisher.publish(
            topic_path,
            data=data,
            retry=retry.Retry(deadline=60.0),
            timeout=60.0,
            **attributes,  # e.g. event_type="ORDER_CREATED", region="us"
        )
        future.add_done_callback(_make_publish_callback(payload["body"][:32]))
        publish_futures.append(future)

    # Wait for every batched publish to complete before returning so callers
    # know the messages are durably accepted (or which ones failed).
    for future in futures.as_completed(publish_futures):
        try:
            future.result()
        except Exception:  # noqa: BLE001
            # Already logged in the callback; swallow here so one failure does
            # not hide the results of the others. Re-raise if you need
            # all-or-nothing semantics.
            logger.error("A publish in the batch did not succeed.")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)

    pub, topic = build_publisher("PROJECT_ID", "TOPIC_ID")
    try:
        publish_messages(
            pub,
            topic,
            payloads=[
                {"body": "order-1001", "event_type": "ORDER_CREATED", "region": "us"},
                {"body": "order-1002", "event_type": "ORDER_CREATED", "region": "eu"},
            ],
        )
    finally:
        # Flush any still-batched messages on shutdown. The client has no
        # close(); stopping its background threads is implicit, but flushing
        # avoids losing the final partial batch.
        pub.stop()
```

**Ordered publishing.** To preserve order for messages that share a key, enable
ordering on the client and pass `ordering_key`. The subscription must also have
message ordering enabled (see [§3.3](#33-message-ordering)).

```python
publisher = pubsub_v1.PublisherClient(
    publisher_options=PublisherOptions(enable_message_ordering=True),
)
future = publisher.publish(topic_path, b"event", ordering_key="customer-42")

# If an ordered publish fails, the client pauses publishing for that key to
# preserve ordering. Resume it after handling the error:
try:
    future.result()
except Exception:
    publisher.resume_publish(topic_path, "customer-42")
```

### 1.2 Subscriber — streaming pull, callback, ack, flow control

The recommended consumer pattern is **streaming pull** via
`subscriber.subscribe()`. The library opens a long-lived stream, invokes your
callback concurrently for each message, and automatically extends ack deadlines
("leases") for messages still being processed. Flow control caps how many
messages are leased at once, preventing memory starvation under load.

```python
"""Production-ready Pub/Sub subscriber using streaming pull.

Demonstrates a message callback, explicit ack/nack, flow control to cap
in-flight messages, and resilient error handling for the stream.
"""

from __future__ import annotations

import logging

from google.cloud import pubsub_v1
from google.cloud.pubsub_v1.subscriber.message import Message
from google.cloud.pubsub_v1.types import FlowControl

logger = logging.getLogger(__name__)


def handle_message(message: Message) -> None:
    """Process a single message, then ack on success or nack on failure.

    The handler MUST be idempotent: Pub/Sub guarantees at-least-once delivery,
    so the same message can arrive more than once.
    """
    try:
        data = message.data.decode("utf-8")
        attributes = dict(message.attributes)
        logger.info(
            "Received message_id=%s data=%r attributes=%s",
            message.message_id,
            data,
            attributes,
        )

        # ---- business logic goes here ----
        # do_work(data, attributes)

        # ack() tells Pub/Sub the message was processed; it will not redeliver.
        message.ack()
    except Exception:  # noqa: BLE001
        logger.exception("Processing failed for message_id=%s", message.message_id)
        # nack() asks for prompt redelivery (subject to retry/backoff policy and
        # any dead-letter topic). Without nack, redelivery waits for the lease
        # to expire.
        message.nack()


def consume(
    project_id: str,
    subscription_id: str,
    *,
    timeout: float | None = None,
) -> None:
    """Open a streaming pull and process messages until cancelled.

    Pass timeout=None to run forever (typical for a long-running worker), or a
    number of seconds for a bounded drain.
    """
    subscriber = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(project_id, subscription_id)

    # Flow control is the key memory-safety knob. max_messages caps how many
    # messages are leased to this client concurrently; max_bytes caps their
    # total size. Tune max_messages to roughly the number you can process in
    # parallel so you never lease more than you can handle.
    flow_control = FlowControl(
        max_messages=100,
        max_bytes=50 * 1024 * 1024,  # 50 MiB outstanding
    )

    # subscribe() returns a StreamingPullFuture. Messages are delivered to the
    # callback on a background thread pool while the main thread blocks below.
    streaming_pull_future = subscriber.subscribe(
        subscription_path,
        callback=handle_message,
        flow_control=flow_control,
    )
    logger.info("Listening on %s ...", subscription_path)

    # Use the client as a context manager so the gRPC channel is closed on exit.
    with subscriber:
        try:
            # result() blocks; it returns when the stream ends or raises if the
            # stream fails irrecoverably.
            streaming_pull_future.result(timeout=timeout)
        except TimeoutError:
            # Bounded-drain case: stop cleanly after the timeout.
            streaming_pull_future.cancel()
            streaming_pull_future.result()  # wait for shutdown to finish
        except Exception:  # noqa: BLE001
            # Stream failed (e.g. unrecoverable error). Cancel and surface it so
            # a supervisor/orchestrator can restart the worker.
            logger.exception("Streaming pull failed; shutting down.")
            streaming_pull_future.cancel()
            streaming_pull_future.result()
            raise


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    consume("PROJECT_ID", "SUBSCRIPTION_ID")
```

**Exactly-once delivery.** On a subscription created with exactly-once delivery,
`ack()`/`nack()` return a future you can check, because the ack is confirmed by
the server. Only treat work as committed once the ack future resolves:

```python
ack_future = message.ack_with_response()
try:
    ack_future.result()  # ack confirmed by the server
except Exception:
    logger.warning("Ack not confirmed; message may be redelivered.")
```

---

## 2. Node.js client library (`@google-cloud/pubsub`)

The Node.js library exposes a single `PubSub` factory from which you obtain
`Topic`/`Publisher` and `Subscription` objects. Like the Python clients, the
`PubSub` instance is **expensive to create** — make one per process and reuse it.

### 2.1 Publisher — attributes, batch settings, promises

`topic.publishMessage()` returns a promise that resolves to the server-assigned
message ID. Batch settings group messages for throughput; the publisher flushes
when any threshold is hit.

```javascript
// publisher.js — production-ready Pub/Sub publisher.
// Demonstrates attributes, batching, flow control, and promise handling.

'use strict';

const {PubSub} = require('@google-cloud/pubsub');

// Create ONE PubSub instance per process and reuse it. Constructing it per
// request leaks gRPC connections and adds latency.
const pubSubClient = new PubSub({projectId: 'PROJECT_ID'});

/**
 * Returns a cached Publisher for a topic with tuned batching + flow control.
 * Reusing the Topic/Publisher object preserves the underlying message batch.
 *
 * @param {string} topicId
 * @returns {import('@google-cloud/pubsub').Topic}
 */
function getTopic(topicId) {
  return pubSubClient.topic(topicId, {
    // A batch is flushed when ANY threshold is reached, whichever comes first.
    batching: {
      maxMessages: 100, // flush after 100 messages
      maxBytes: 1 * 1024 * 1024, // ...or 1 MiB
      maxMilliseconds: 50, // ...or 50 ms, to bound publish latency
    },
    // Publisher flow control caps outstanding (un-acked-by-server) publishes
    // so a burst cannot exhaust memory.
    flowControlOptions: {
      maxOutstandingMessages: 1000,
      maxOutstandingBytes: 10 * 1024 * 1024, // 10 MiB
    },
  });
}

/**
 * Publish a single message with custom attributes.
 *
 * @param {string} topicId
 * @param {string} body - the message payload
 * @param {Record<string, string>} attributes - string->string metadata
 * @returns {Promise<string>} the server-assigned message ID
 */
async function publishMessage(topicId, body, attributes = {}) {
  const topic = getTopic(topicId);

  try {
    // Data MUST be a Buffer. Attributes MUST be string -> string.
    const messageId = await topic.publishMessage({
      data: Buffer.from(body, 'utf8'),
      attributes,
    });
    console.log(`Published message ${messageId} (${body})`);
    return messageId;
  } catch (err) {
    // The client already retries transient errors internally; reaching here
    // means it gave up. Surface it so the caller can decide what to do.
    console.error(`Failed to publish "${body}":`, err);
    throw err;
  }
}

/**
 * Publish many messages concurrently and wait for all results.
 * Promise.allSettled lets one failure not abort the rest.
 *
 * @param {string} topicId
 * @param {Array<{body: string, attributes?: Record<string,string>}>} messages
 */
async function publishBatch(topicId, messages) {
  const results = await Promise.allSettled(
    messages.map((m) => publishMessage(topicId, m.body, m.attributes ?? {}))
  );

  const failed = results.filter((r) => r.status === 'rejected');
  if (failed.length > 0) {
    console.error(`${failed.length}/${messages.length} publishes failed.`);
  }
  return results;
}

// Example usage.
async function main() {
  await publishBatch('TOPIC_ID', [
    {body: 'order-1001', attributes: {eventType: 'ORDER_CREATED', region: 'us'}},
    {body: 'order-1002', attributes: {eventType: 'ORDER_CREATED', region: 'eu'}},
  ]);

  // Flush any still-batched messages before the process exits.
  await pubSubClient.close();
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}

module.exports = {getTopic, publishMessage, publishBatch};
```

**Ordered publishing.** Set `messageOrdering: true` on the topic options and pass
an `orderingKey`. If an ordered publish fails, resume the key before publishing
again:

```javascript
const topic = pubSubClient.topic('TOPIC_ID', {messageOrdering: true});
try {
  await topic.publishMessage({
    data: Buffer.from('event'),
    orderingKey: 'customer-42',
  });
} catch (err) {
  // Publishing for this key is paused after a failure to preserve order.
  topic.resumePublishing('customer-42');
  throw err;
}
```

### 2.2 Subscriber — message/error events, options, flow control

`subscription.on('message', ...)` opens a streaming pull and emits an event per
message. The `Message` object carries `ack()`/`nack()`. Subscriber options cap
the number of leased messages (flow control) so the process does not run out of
memory under a backlog.

```javascript
// subscriber.js — production-ready Pub/Sub subscriber.
// Demonstrates message/error event handlers, flow control, ack/nack, and a
// clean shutdown.

'use strict';

const {PubSub} = require('@google-cloud/pubsub');

const pubSubClient = new PubSub({projectId: 'PROJECT_ID'});

/**
 * Start listening on a subscription. Returns the Subscription so the caller
 * can close it on shutdown.
 *
 * @param {string} subscriptionId
 * @returns {import('@google-cloud/pubsub').Subscription}
 */
function startConsumer(subscriptionId) {
  const subscription = pubSubClient.subscription(subscriptionId, {
    flowControl: {
      // Cap concurrently-leased messages so memory stays bounded. Set this
      // near how many you can process in parallel.
      maxMessages: 100,
      maxBytes: 50 * 1024 * 1024, // 50 MiB outstanding
      // allowExcessMessages:false keeps the client from buffering beyond the
      // limits while waiting for handlers to finish.
      allowExcessMessages: false,
    },
    // Number of streaming-pull connections; raise for very high throughput.
    streamingOptions: {maxStreams: 5},
  });

  // Per-message handler. MUST be idempotent (at-least-once delivery).
  const onMessage = async (message) => {
    try {
      const data = message.data.toString('utf8');
      console.log(
        `Received ${message.id} data=${data} attrs=${JSON.stringify(
          message.attributes
        )}`
      );

      // ---- business logic goes here ----
      // await doWork(data, message.attributes);

      // ack() confirms processing; Pub/Sub will not redeliver.
      message.ack();
    } catch (err) {
      console.error(`Processing failed for ${message.id}:`, err);
      // nack() requests prompt redelivery (subject to retry/dead-letter policy).
      message.nack();
    }
  };

  // The 'error' event fires for stream-level failures (auth, network). The
  // client reconnects automatically for transient errors; log so persistent
  // failures are visible.
  const onError = (err) => {
    console.error('Subscription error:', err);
  };

  subscription.on('message', onMessage);
  subscription.on('error', onError);

  console.log(`Listening on ${subscriptionId} ...`);
  return subscription;
}

async function main() {
  const subscription = startConsumer('SUBSCRIPTION_ID');

  // Graceful shutdown: stop receiving, let in-flight handlers finish, then
  // close. removeListener + close() prevents leaked streams.
  const shutdown = async () => {
    console.log('Shutting down...');
    subscription.removeAllListeners();
    await subscription.close();
    await pubSubClient.close();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}

module.exports = {startConsumer};
```

---

## 3. Best practices for developers

### 3.1 Reuse the client instance

Both libraries open and pool gRPC connections inside the client. Creating a
client per request (a common mistake in web handlers and serverless functions)
leaks connections, exhausts file descriptors, defeats batching, and adds
connection-setup latency to every call.

- **Create the client once** at module load / process start and reuse it for the
  life of the process.
- In serverless runtimes (Cloud Run, Cloud Functions), declare the client in
  **global/module scope**, not inside the request handler. It is then reused
  across warm invocations on the same instance.
- The publisher batches across calls only if you reuse the same publisher/topic
  object — a fresh object each time means batches of one.

```python
# Python — module scope, created once, imported wherever needed.
from google.cloud import pubsub_v1

publisher = pubsub_v1.PublisherClient()
subscriber = pubsub_v1.SubscriberClient()
```

```javascript
// Node.js — module scope, created once.
const {PubSub} = require('@google-cloud/pubsub');
const pubSubClient = new PubSub();
module.exports = pubSubClient;
```

### 3.2 Handle transient errors and network retries

Pub/Sub is a distributed service; transient `UNAVAILABLE`, `DEADLINE_EXCEEDED`,
and `INTERNAL` errors are expected and should be retried with exponential
backoff. Both client libraries retry idempotent operations **automatically**, so
prefer configuring the built-in retry/timeout over writing your own loop.

- **Publishing:** rely on the library's retry; tune the deadline so a retry storm
  doesn't outlive the message's usefulness. In Python pass `retry=` and
  `timeout=` to `publish()` ([§1.1](#11-publisher--async-publishing-attributes-futures-flow-control));
  in Node.js configure `gaxOpts.retry` on the topic's publish settings. Surface
  the error only after the library exhausts retries.
- **Consuming:** the streaming pull reconnects automatically on transient stream
  failures. Your job is to make message processing **idempotent** so a redelivery
  after a reconnect is harmless, and to `nack()` (or simply let the lease lapse)
  on processing failure so the message is retried.
- **Poison messages:** bound retries with a **dead-letter topic** and
  `--max-delivery-attempts` ([`cli-usage.md`](cli-usage.md) §2.1) so a message
  that always fails is isolated instead of retried forever.
- **Backpressure:** when the backend is slow, publisher **flow control** with
  `BLOCK` behavior applies backpressure to the producer instead of buffering
  unboundedly. Prefer it over unbounded in-memory queues.

```python
# Python — explicit publish retry with a bounded total deadline.
from google.api_core import retry

future = publisher.publish(
    topic_path,
    data=b"payload",
    retry=retry.Retry(
        initial=0.1,    # first backoff 100 ms
        maximum=60.0,   # cap individual backoff at 60 s
        multiplier=2.0, # exponential
        deadline=600.0, # give up after 10 minutes total
    ),
    timeout=600.0,
)
```

### 3.3 Message ordering

Ordering guarantees that messages sharing an **ordering key** are delivered to a
subscriber in publish order. It is opt-in on both the publisher and the
subscription.

- **Enable on the publisher** (`enable_message_ordering` / `messageOrdering:
  true`) **and** on the subscription (`--enable-message-ordering` at creation —
  see [`cli-usage.md`](cli-usage.md) §2.1). Both sides are required.
- **Always set an ordering key** for messages that must be ordered (e.g. a
  per-entity ID like `customer-42`). Messages with different keys are still
  delivered in parallel, so order is preserved per key without serializing the
  whole topic.
- **Resume after failure.** If an ordered publish fails, the client pauses that
  key to preserve order; call `resume_publish()` /
  `resumePublishing()` after handling the error before publishing more for that
  key.
- **Cost of ordering:** throughput per ordering key is limited and a stuck
  message blocks its key's queue. Keep keys fine-grained, and only enable
  ordering where the domain truly requires it.

### 3.4 Deduplication strategies

Pub/Sub delivers **at-least-once** by default, so consumers must tolerate
duplicates. Choose a strategy based on the guarantee you need:

1. **Idempotent processing (recommended baseline).** Design handlers so applying
   the same message twice has the same effect as once — e.g. upsert by a natural
   key, use `INSERT ... ON CONFLICT DO NOTHING`, or make state transitions
   conditional. This is the most robust approach and works regardless of
   delivery semantics.
2. **Dedup on a business/idempotency key.** Carry a stable unique ID in a message
   **attribute** (e.g. `event_id`) and record processed IDs in a fast store
   (Redis, Firestore, a DB unique constraint) with a TTL longer than the
   subscription's retention. Skip a message whose ID was already processed.
   Prefer a domain key over Pub/Sub's `message_id`, since a republish (retry by
   the producer) yields a new `message_id` for the same logical event.
3. **Exactly-once delivery subscriptions.** Create the subscription with
   `--enable-exactly-once-delivery` ([`cli-usage.md`](cli-usage.md) §2.1). Within
   the ack deadline Pub/Sub guarantees a successfully-acked message is not
   redelivered. Use `ack_with_response()` (Python) / await the ack result and
   only commit work once the ack is confirmed
   ([§1.2](#12-subscriber--streaming-pull-callback-ack-flow-control)). This
   reduces — but, across very long processing windows, does not entirely remove —
   the need for idempotency, so keep handlers idempotent as defense in depth.

> [!TIP]
> Combine strategies: enable exactly-once where latency allows, **and** keep
> handlers idempotent. Ordering + exactly-once + an idempotency key covers the
> strongest end-to-end requirements.

---

## Related references

- [`cli-usage.md`](cli-usage.md) — `gcloud pubsub` commands for creating topics,
  subscriptions (including ordering, exactly-once, and dead-letter flags),
  schemas, and snapshots.
- [`iam-security.md`](iam-security.md) — IAM roles the publishing/consuming
  identities need, least-privilege binding patterns, and dead-letter permissions.
- [`../SKILL.md`](../SKILL.md) — Skill overview, core concepts, and the safety
  denylist governing destructive operations.
</content>
</invoke>
