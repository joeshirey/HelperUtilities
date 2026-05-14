# Restricting Cloud Run access by Google email domain

How to lock down a Cloud Run service so only users from specific email domains can reach it. Three approaches, each with different tradeoffs:

| Approach | Code changes? | Custom domain? | Cost | Complexity |
|----------|---------------|----------------|------|------------|
| 1. oauth2-proxy sidecar (recommended) | None | No | Free | Medium |
| 2. Code-level auth middleware | Yes | No | Free | Low |
| 3. IAP + Load Balancer | None | Yes | ~$18+/mo | High |

## Picking an approach

The sidecar (Approach 1) works with any language, any framework, any existing container. Your app never knows auth is happening. If you want zero code changes, this is the one.

Code-level auth (Approach 2) is simpler to deploy since it's a single container with no multi-container YAML. But you're writing auth middleware yourself, and it's framework-specific.

IAP + Load Balancer (Approach 3) is the cleanest if you have a custom domain. Google manages everything. The catch is you need that domain, and the load balancer runs about $18/mo.

```
Do you have a custom domain with DNS control?
├── Yes --> Mind ~$18/mo for a load balancer?
│   ├── Yes --> Approach 1 (sidecar) or Approach 2 (code-level)
│   └── No  --> Approach 3 (IAP + LB), fully managed
└── No  --> Want to avoid all code changes?
    ├── Yes --> Approach 1 (sidecar)
    └── No  --> Approach 2 (code-level), simplest deployment
```

---

## Approach 1: oauth2-proxy sidecar (recommended)

[oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) is an open source reverse proxy that handles OAuth. It runs as a sidecar container alongside your app in the same Cloud Run service. No separate service, no load balancer, no custom domain, no code changes.

### How it works

```
Internet --> Cloud Run (port 8080)
              |
              v
          oauth2-proxy (sidecar)
              |
              |-- No session cookie? --> Redirect to Google Sign-In
              |                               |
              |                               v
              |                         User signs in
              |                               |
              |                               v
              |                         Domain in allow-list?
              |                         |-- No  --> 403 Forbidden
              |                         '-- Yes --> Set session cookie, redirect back
              |
              '-- Valid session cookie? --> Proxy to app (localhost:8081)
                                               |
                                               v
                                          Your app sees a normal HTTP request.
                                          No auth headers, no tokens.
```

1. Cloud Run routes traffic to the oauth2-proxy container (port 8080)
2. oauth2-proxy checks for a valid session cookie
3. No session? Redirect to Google Sign-In
4. After sign-in, oauth2-proxy checks the email domain against the allow-list
5. If allowed, it proxies the request to your app on localhost:8081
6. Your app gets a plain HTTP request and has no idea auth happened

### Prerequisites

- `gcloud` CLI installed and authenticated
- An existing Cloud Run service
- The service's container image (the companion script retrieves this automatically)

### Step 1: Configure the OAuth consent screen

1. Go to: `https://console.cloud.google.com/apis/credentials/consent?project=<PROJECT_ID>`
2. Set User Type to External
   - Do not choose Internal. Internal restricts sign-in to users within your Workspace org. If you're allowing multiple domains (say `google.com` and `example.com`) but your org is `example.com`, Internal blocks `google.com` users at Google's sign-in page before your proxy even sees the request.
3. Fill in the required fields: app name, support email, developer contact email
4. On the Scopes page, add: `email`, `profile`
5. Skip Test Users, click Save
6. Back on the dashboard, click Publish App

Publishing is required. In Testing mode, only explicitly listed test users can sign in. Since you're only requesting `email` and `profile` scopes, Google does not require verification to publish.

### Step 2: Create OAuth client credentials

1. Go to: `https://console.cloud.google.com/apis/credentials?project=<PROJECT_ID>`
2. Click + Create Credentials > OAuth client ID
3. Application type: Web application
4. Under Authorized redirect URIs, add:
   ```
   https://<YOUR_CLOUD_RUN_URL>/oauth2/callback
   ```
   oauth2-proxy uses `/oauth2/callback`, not `/auth/callback`. Easy to mix up.
5. Click Create and copy the Client ID and Client Secret

You need one OAuth client per Cloud Run service. Each service has a different URL, so each needs its own redirect URI. The consent screen is shared across all clients in the project.

To find your Cloud Run URL:
```bash
gcloud run services describe <SERVICE> --region=<REGION> --project=<PROJECT> --format='value(status.url)'
```

Generate a cookie secret:
```bash
openssl rand -hex 16
```

Do not use an auto-generated IAP OAuth client. Those are locked and won't let you add redirect URIs. If you see "This automatically generated OAuth client ID... can't be modified," create a new one under APIs & Services > Credentials.

### Step 3: Set up Artifact Registry for the oauth2-proxy image

Cloud Run only allows images from `gcr.io`, Artifact Registry (`*.pkg.dev`), or Docker Hub (`docker.io`). The oauth2-proxy image lives on `quay.io`, which Cloud Run rejects.

The workaround is an Artifact Registry remote repository that proxies quay.io. One-time setup per project/region:

```bash
gcloud artifacts repositories create quay-remote \
  --repository-format=docker \
  --location=<REGION> \
  --mode=remote-repository \
  --remote-docker-repo=https://quay.io \
  --project=<PROJECT_ID>
```

Cloud Run pulls through Artifact Registry, which fetches from quay.io on first access and caches it. The image reference becomes:
```
<REGION>-docker.pkg.dev/<PROJECT_ID>/quay-remote/oauth2-proxy/oauth2-proxy:v7.7.1
```

### Step 4: Generate the service YAML

The sidecar setup needs a Cloud Run service YAML with two containers. The companion script (`setup-cloud-run-oauth.sh`) generates this automatically. It retrieves your current container image, preserves existing environment variables, creates the AR remote repo if needed, and produces the YAML.

You can also write the YAML by hand:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: <SERVICE_NAME>
spec:
  template:
    metadata:
      annotations:
        run.googleapis.com/container-dependencies: '{"oauth-proxy":["app"]}'
    spec:
      containers:
      - name: oauth-proxy
        image: <REGION>-docker.pkg.dev/<PROJECT_ID>/quay-remote/oauth2-proxy/oauth2-proxy:v7.7.1
        args:
        - "--provider=google"
        - "--client-id=<CLIENT_ID>"
        - "--client-secret=<CLIENT_SECRET>"
        - "--cookie-secret=<COOKIE_SECRET>"
        - "--email-domain=domain1.com"
        - "--email-domain=domain2.com"
        - "--upstream=http://localhost:8081/"
        - "--http-address=0.0.0.0:8080"
        - "--reverse-proxy=true"
        - "--skip-provider-button=true"
        - "--cookie-secure=true"
        ports:
        - containerPort: 8080
      - name: app
        image: <YOUR_APP_IMAGE>
        startupProbe:
          httpGet:
            path: /
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 6
          timeoutSeconds: 5
        env:
        - name: PORT
          value: "8081"
        # ... your app's existing env vars ...
```

#### Things that matter

Use CLI args, not env vars. oauth2-proxy v7.x does not reliably read `OAUTH2_PROXY_UPSTREAM` from the environment. The upstream never gets registered and every request returns 404 after auth. Passing `--upstream` as a container arg works. You can verify by checking the startup log for `mapping path "/" => upstream "http://localhost:8081/"`. If that line is missing, the upstream isn't configured.

The upstream URL needs a trailing slash: `http://localhost:8081/`, not `http://localhost:8081`. Without it, oauth2-proxy may silently fail to route requests.

Repeat `--email-domain` for each domain. CLI args take one flag per domain, unlike the env var which was comma-separated.

The `container-dependencies` annotation tells Cloud Run to start the app container before the proxy. The proxy won't work if the upstream isn't ready.

`--skip-provider-button=true` skips the "Sign in with Google" interstitial and sends users straight to Google's sign-in page.

`--cookie-secure=true` is required. Cloud Run terminates TLS, so the proxy always sees HTTPS.

The `startupProbe` on the app container is required. Cloud Run won't start containers that depend on another container unless that container has a startup probe. The example gives 65 seconds total (5s initial delay + 6 failures x 10s interval). Adjust for your app's startup time.

#### Cookie secret sizing

The cookie secret must be exactly 16, 24, or 32 bytes for AES.

```bash
# Correct: 32 hex chars = 16 bytes
openssl rand -hex 16

# Wrong: 44 base64 chars = 44 bytes, rejected
openssl rand -base64 32
```

Base64 encoding inflates the byte count (32 raw bytes become 44 base64 characters), and oauth2-proxy treats the string as raw bytes. Stick with hex.

#### Apps that hardcode their port

If your Dockerfile CMD hardcodes a port (e.g., `CMD ["uvicorn", "...", "--port", "8080"]`), the app will fight with oauth2-proxy over port 8080.

Override the CMD in the YAML without touching any code:

```yaml
      - name: app
        image: <YOUR_APP_IMAGE>
        command: ["uvicorn"]
        args: ["myapp:app", "--host", "0.0.0.0", "--port", "8081"]
```

If your app reads the `PORT` environment variable, you don't need the override. Just set `PORT: "8081"` in the env section.

### Step 5: Deploy

```bash
gcloud run services replace service.yaml --region=<REGION> --project=<PROJECT_ID>
```

After deployment, make sure the service allows unauthenticated access at the Cloud Run IAM level (oauth2-proxy handles auth, not IAM):

```bash
gcloud run services add-iam-policy-binding <SERVICE> \
  --member="allUsers" --role="roles/run.invoker" \
  --region=<REGION> --project=<PROJECT_ID>
```

### Step 6: Verify

#### Manual verification
1. Open your Cloud Run URL. You should be redirected to Google Sign-In.
2. Sign in with an allowed domain. You should see your app.
3. In an incognito window, sign in with a different domain. You should get a 403.

#### Automated end-to-end validation
If you want to test this entire sidecar approach in your GCP project before touching your real application, run the automated validation harness:

```bash
./validate-deployment.sh
```

The script will:
1. Deploy a temporary, public `hello-app` container to Cloud Run
2. Guide you through running `setup-cloud-run-oauth.sh` against the temporary service
3. Automatically verify that unauthenticated requests return an HTTP `302` redirect to Google OAuth and that `allUsers` has invoker permissions
4. Clean up the temporary Cloud Run service and generated YAML files when you are done


---

## Approach 2: Code-level auth middleware

Instead of a sidecar, you add OAuth middleware directly to your application. Simpler to deploy (single container, normal `gcloud run deploy`), but you're writing auth code and coupling it to your app.

### How it works

```
Internet --> Cloud Run (port 8080)
              |
              v
          Your app (with auth middleware)
              |
              |-- No session cookie? --> Redirect to Google Sign-In
              |-- Valid session, wrong domain? --> 403 Forbidden
              '-- Valid session, allowed domain? --> Serve the request
```

The middleware intercepts every request before your route handlers. It manages the OAuth flow, session cookies, and domain checking inside your application process.

### When this makes sense

- You're building a new app and can add auth from the start
- You want a single-container deployment with no YAML
- You're comfortable owning the auth middleware for your framework
- You don't need to protect services in other languages/frameworks

### Example: Node.js / Express wrapper

For static sites or apps without built-in auth, wrap them with an Express server:

```javascript
// server.js
const express = require('express');
const session = require('express-session');
const { OAuth2Client } = require('google-auth-library');

const app = express();
const PORT = process.env.PORT || 8080;
const ALLOWED_DOMAINS = (process.env.ALLOWED_DOMAINS || '').split(',');
const CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;

// Session middleware
app.use(session({
  secret: process.env.SESSION_SECRET || require('crypto').randomBytes(32).toString('hex'),
  resave: false,
  saveUninitialized: false,
  cookie: { secure: true, maxAge: 7 * 24 * 60 * 60 * 1000 } // 7 days
}));

// OAuth2 client
const oauth2Client = new OAuth2Client(CLIENT_ID, CLIENT_SECRET);

// Auth check middleware
app.use((req, res, next) => {
  // Allow the callback route
  if (req.path === '/auth/callback') return next();

  // Check for valid session
  if (req.session && req.session.email) {
    const domain = req.session.email.split('@')[1];
    if (ALLOWED_DOMAINS.includes(domain)) return next();
    return res.status(403).send('Access denied: domain not allowed');
  }

  // Redirect to Google Sign-In
  const redirectUri = `${req.protocol}://${req.get('host')}/auth/callback`;
  const authUrl = oauth2Client.generateAuthUrl({
    access_type: 'offline',
    scope: ['email', 'profile'],
    redirect_uri: redirectUri,
  });
  res.redirect(authUrl);
});

// OAuth callback
app.get('/auth/callback', async (req, res) => {
  const redirectUri = `${req.protocol}://${req.get('host')}/auth/callback`;
  const { tokens } = await oauth2Client.getToken({ code: req.query.code, redirect_uri: redirectUri });
  const ticket = await oauth2Client.verifyIdToken({ idToken: tokens.id_token, audience: CLIENT_ID });
  const payload = ticket.getPayload();

  req.session.email = payload.email;
  res.redirect('/');
});

// Serve your static site
app.use(express.static('dist'));

// SPA fallback
app.get('*', (req, res) => res.sendFile('index.html', { root: 'dist' }));

app.listen(PORT);
```

Dependencies: `express`, `express-session`, `google-auth-library`

Dockerfile CMD: `CMD ["node", "server.js"]`

Environment variables on Cloud Run:
- `GOOGLE_CLIENT_ID` - your OAuth client ID
- `GOOGLE_CLIENT_SECRET` - your OAuth client secret
- `ALLOWED_DOMAINS` - comma-separated (e.g., `google.com,example.com`)

OAuth redirect URI: `https://<YOUR_URL>/auth/callback` (not `/oauth2/callback` like the sidecar uses)

### Sidecar vs. code-level

| | Sidecar (Approach 1) | Code-level (Approach 2) |
|---|---|---|
| Code changes | None | Yes, add middleware + dependencies |
| Deployment | Multi-container YAML via `gcloud run services replace` | Single container via `gcloud run deploy` |
| Port management | Must avoid 8080 conflict; may need CMD override | No conflict, single process |
| Framework support | Any (auth is external to the app) | Implement per framework |
| Session storage | Cookies, managed by oauth2-proxy | Your responsibility (in-memory, Redis, etc.) |
| Callback path | `/oauth2/callback` | `/auth/callback` (or whatever you choose) |
| Updating auth config | Redeploy the YAML or update env vars | Redeploy the entire app |
| App redeployment | Must use `gcloud run services replace` or `--container app`. `--source` removes the sidecar. | Normal `gcloud run deploy --source` works |

Both approaches need a separate OAuth client per Cloud Run service, since each has a different URL and redirect URI. The consent screen is shared across all clients in the project.

---

## Approach 3: IAP + Load Balancer

If you have a custom domain with DNS control, Identity-Aware Proxy (IAP) is the GCP-native solution. No code changes, no sidecar. Google handles everything.

### Steps

1. Create a Serverless Network Endpoint Group (NEG)
   ```bash
   gcloud compute network-endpoint-groups create <NEG_NAME> \
     --region=<REGION> --network-endpoint-type=serverless \
     --cloud-run-service=<SERVICE> --project=<PROJECT>
   ```

2. Create a Backend Service
   ```bash
   gcloud compute backend-services create <BACKEND_NAME> \
     --global --load-balancing-scheme=EXTERNAL_MANAGED --project=<PROJECT>
   gcloud compute backend-services add-backend <BACKEND_NAME> \
     --global --network-endpoint-group=<NEG_NAME> \
     --network-endpoint-group-region=<REGION> --project=<PROJECT>
   ```

3. Create a URL Map, SSL Cert, HTTPS Proxy, and Forwarding Rule
   ```bash
   gcloud compute url-maps create <MAP_NAME> \
     --default-service=<BACKEND_NAME> --project=<PROJECT>
   gcloud compute ssl-certificates create <CERT_NAME> \
     --domains=<YOUR_DOMAIN> --project=<PROJECT>
   gcloud compute target-https-proxies create <PROXY_NAME> \
     --url-map=<MAP_NAME> --ssl-certificates=<CERT_NAME> --project=<PROJECT>
   gcloud compute addresses create <IP_NAME> --global --project=<PROJECT>
   gcloud compute forwarding-rules create <RULE_NAME> --global \
     --target-https-proxy=<PROXY_NAME> --address=<IP_NAME> \
     --ports=443 --load-balancing-scheme=EXTERNAL_MANAGED --project=<PROJECT>
   ```

4. Point your domain's DNS to the reserved IP address (A record)

5. Enable IAP
   ```bash
   gcloud services enable iap.googleapis.com --project=<PROJECT>
   gcloud compute backend-services update <BACKEND_NAME> \
     --global --iap=enabled --project=<PROJECT>
   ```

6. Grant access by domain
   ```bash
   gcloud iap web add-iam-policy-binding \
     --resource-type=backend-services --service=<BACKEND_NAME> \
     --member="domain:<ALLOWED_DOMAIN>" \
     --role="roles/iap.httpsResourceAccessor" --project=<PROJECT>
   ```

7. Lock down Cloud Run and grant IAP invoker access
   ```bash
   gcloud run services remove-iam-policy-binding <SERVICE> \
     --member="allUsers" --role="roles/run.invoker" \
     --region=<REGION> --project=<PROJECT>

   PROJECT_NUMBER=$(gcloud projects describe <PROJECT> --format='value(projectNumber)')
   gcloud run services add-iam-policy-binding <SERVICE> \
     --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com" \
     --role="roles/run.invoker" --region=<REGION> --project=<PROJECT>
   ```

### Why you need a custom domain

IAP checks that the SSL certificate matches the request hostname. Hit a load balancer by IP and the cert has no matching hostname, so IAP returns error code 52. A self-signed cert won't work either since the CN won't match what's in the browser's address bar. Google-managed SSL certs require a real domain name.

---

## OAuth consent screen: gotchas that apply to Approaches 1 and 2

### External vs. Internal

| Setting | Who can sign in | Use when |
|---------|----------------|----------|
| External | Anyone with a Google account (your app/proxy filters by domain) | You want to allow multiple domains |
| Internal | Only users in your Workspace org | Single org only |

If you allow multiple domains, use External. Internal blocks users outside your Workspace org at Google's sign-in page, before your proxy or middleware ever sees the request. Domain filtering happens downstream in oauth2-proxy or your code.

### You have to publish the app

The consent screen must be published, not in Testing mode. In Testing mode, only users you've explicitly added as test users can sign in, regardless of domain. Publishing with `email` and `profile` scopes doesn't require Google verification.

---

## Troubleshooting

### Error 400: redirect_uri_mismatch

The redirect URI in your OAuth client doesn't match the callback URL. Things to check:

- oauth2-proxy (Approach 1) uses `/oauth2/callback`
- Code-level auth (Approach 2) uses `/auth/callback` (or whatever you configured)
- These are different. Easy to mix up.
- The full URI must match exactly, protocol included (`https://`)
- Cloud Run URLs can change on redeployment:
  ```bash
  gcloud run services describe <SERVICE> --region=<REGION> --project=<PROJECT> --format='value(status.url)'
  ```
- Each Cloud Run service needs its own OAuth client with its own redirect URI

### Users from an allowed domain get blocked at Google's sign-in page

The consent screen is set to Internal instead of External. Go to APIs & Services > OAuth consent screen, switch to External, and publish.

### "This automatically generated OAuth client ID... can't be modified"

That's an IAP-generated OAuth client. They're locked. Create a new one under APIs & Services > Credentials > + Create Credentials > OAuth client ID.

### Cookie secret rejected: must be 16, 24, or 32 bytes

oauth2-proxy needs the cookie secret to be exactly 16, 24, or 32 bytes for AES.

```bash
# Correct: 32 hex chars = 16 bytes
openssl rand -hex 16

# Wrong: 44 base64 chars = 44 bytes, rejected
openssl rand -base64 32
```

### Cloud Run rejects the oauth2-proxy image

Cloud Run only pulls from `gcr.io`, `*.pkg.dev`, or `docker.io`. The oauth2-proxy image is on `quay.io`. Create an Artifact Registry remote repo to proxy it:

```bash
gcloud artifacts repositories create quay-remote \
  --repository-format=docker \
  --location=<REGION> \
  --mode=remote-repository \
  --remote-docker-repo=https://quay.io \
  --project=<PROJECT_ID>
```

Then reference: `<REGION>-docker.pkg.dev/<PROJECT_ID>/quay-remote/oauth2-proxy/oauth2-proxy:v7.7.1`

### "404 page not found" after signing in successfully

You get through Google Sign-In fine, get redirected back, and see a plain-text "404 page not found" (Go's default 404, not your app's).

This means oauth2-proxy authenticated you but has no upstream to forward to. Two causes:

1. You used environment variables instead of CLI args. oauth2-proxy v7.x doesn't reliably pick up `OAUTH2_PROXY_UPSTREAM` from env vars. Switch to `args` in the YAML. Check the startup logs for `mapping path "/" => upstream "http://localhost:8081/"`. If that line is missing, the upstream was never registered.

2. The upstream URL is missing its trailing slash. `--upstream=http://localhost:8081/` works. `--upstream=http://localhost:8081` doesn't.

### CSRF cookie error on the OAuth callback

```
AuthFailure Invalid authentication via OAuth2: unable to obtain CSRF cookie
```

Stale cookies from a previous deployment. Each deploy generates a new cookie secret, so old session cookies are invalid. Open the site in an incognito window or clear cookies for the domain. If you're iterating on the setup, just do all testing in incognito.

### Startup probe fails with ERROR_CONNECTION_FAILED

The app container isn't listening where the probe expects. Common reasons:

1. The Dockerfile CMD hardcodes a port (like `--port 8080`) instead of reading the `PORT` env var, so the app binds to 8080 while the probe checks 8081. Fix with a `command`/`args` override in the YAML.
2. The app takes longer to start than the probe allows. Increase `failureThreshold` and `initialDelaySeconds`. Total time allowed is `initialDelaySeconds + (failureThreshold x periodSeconds)`.
3. Wrong health check path. Use `/` for static sites, `/api/health` or `/health` for API servers.

### IAP error code 52

Hostname/SSL cert mismatch. You need a custom domain with a matching SSL certificate. Use the sidecar approach (Approach 1) if you don't have one.

### App works locally but returns 502 with the sidecar

The app container must be listening on port 8081 (or wherever `--upstream` points). If the app ignores the `PORT` env var, add a `command`/`args` override in the YAML.

### Users have to re-login constantly

oauth2-proxy session cookies last 168 hours (7 days) by default. Adjust with `--cookie-expire` in the args.

### Deploying with `--source` removes the sidecar

`gcloud run deploy --source` replaces the entire service spec with a single container, wiping out the sidecar. After adding oauth2-proxy, always deploy with `gcloud run services replace` using the service YAML, or update just the app image:
```bash
gcloud run deploy <SERVICE> --container app --image <NEW_IMAGE> \
  --region=<REGION> --project=<PROJECT>
```
