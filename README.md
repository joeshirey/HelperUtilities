# HelperUtilities

General collection of useful things I build.

## Cloud Run auth (`/CloudRunAuth`)

If you need to lock down a Google Cloud Run service so only people from specific email domains (like `@yourcompany.com`) can access it, this directory has what you need.

It includes a detailed breakdown of three different ways to handle domain filtering:
- An `oauth2-proxy` sidecar container (the cleanest option if you don't want to touch your application code)
- Code-level Express middleware
- Identity-Aware Proxy (IAP) paired with an external load balancer

There is also an automated setup script (`setup-cloud-run-oauth.sh`) that inspects your existing Cloud Run service and generates the multi-container Knative YAML required to deploy the sidecar proxy.

Check the [CloudRunAuth README](CloudRunAuth/README.md) for the full guide and deployment instructions.
