# Quiz — AWS API Gateway

Five questions. Answers are collapsed — no peeking until you've answered.

---

### 1. You are building a typical JSON microservice API (CRUD over Lambda, JWT auth). Which API Gateway type should you pick, and why?

<details>
<summary>Answer</summary>

**HTTP API.** It has the lowest latency, the lowest cost (~$1.00 vs ~$3.50
per million requests for REST), and supports JWT and Lambda authorizers —
everything a typical microservice needs. Reach for REST API only when you
need its exclusive features: usage plans with API keys/quotas, built-in
response caching, or request/response transformation.

</details>

---

### 2. Your Lambda authorizer is invoked on every single request and it's showing up in your bill. What's the fix, and what should you be careful about?

<details>
<summary>Answer</summary>

Set `authorizer_result_ttl_in_seconds` so allow decisions are cached and
repeat callers skip re-authentication. The catch: cache **deny** decisions
with a short TTL (or not at all) — a long deny TTL can lock a legitimate
user out for minutes after a transient failure or a just-fixed token.

</details>

---

### 3. What's the difference between throttling and quotas, and where is each configured?

<details>
<summary>Answer</summary>

**Throttling** (rate + burst limits) protects *your backend* from traffic
spikes — configured per-route or per-stage on any API type; abusive
clients get `429`. **Quotas** (e.g. 10,000 requests/month) protect *your
business model* — configured via **usage plans** with API keys, available
only on **REST APIs**.

</details>

---

### 4. You want to ship a new version of your API with minimal risk. How do API Gateway stages help, and what's the IaC rule?

<details>
<summary>Answer</summary>

Use **canary releases** on the stage: route a small percentage of traffic
(e.g. 10%) to the new deployment, watch `5XXError` and latency in
CloudWatch, then promote or roll back. The IaC rule: gateway config is
infrastructure — change it in Terraform and deploy through CI. Console
edits drift silently and get overwritten (or worse, never reproduced).

</details>

---

### 5. Your Lambda takes 45 seconds to generate a large report, but clients keep getting `504`. What's happening, and what's the proper fix?

<details>
<summary>Answer</summary>

API Gateway caps integration timeouts at **29s (REST) / 30s (HTTP)**.
After that the gateway returns `504` — while your Lambda *keeps running
and billing*. The fix is architectural, not a timeout tweak: return `202
Accepted` immediately, run the report asynchronously (SQS + Lambda, or
Step Functions), and let the client poll or receive a webhook/callback
when it's done.

</details>

---

**Score:** 5/5 — gateway whisperer. 3–4 — solid, re-read the pitfalls.
0–2 — start again at "Which API type?" 🙂
