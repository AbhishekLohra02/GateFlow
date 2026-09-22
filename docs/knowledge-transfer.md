# GateFlow — Knowledge Transfer

A plain-language record of what this project is, how it was built, and why
each decision was made. No code. Read top to bottom and you should be able
to explain the whole system to someone else.

Kept up to date as the project progresses.

---

## 1. What GateFlow is

GateFlow is a delivery pipeline. A small web application is the payload; the
pipeline that ships it is the actual engineering.

The goal: **a developer merges a change, and that change reaches production
without anyone running a deployment command — but not without a human
approving it first.**

Every release passes through a sequence of automated gates:

1. Someone opens a pull request. Tests, a container build, a security scan
   and an infrastructure preview all run. Nothing merges unless all pass.
2. On merge, the application image is published to a registry.
3. It deploys automatically to **dev**, and is tested there.
4. It promotes to **staging**, and is tested again.
5. It stops and waits for a **human approval**.
6. On approval it rolls out to **production**, is tested once more, and
   rolls itself back automatically if that test fails.

The name comes from step 5. Most tutorial pipelines deploy straight through;
the approval gate is the part that makes this resemble something a company
would actually run.

---

## 2. The application

Deliberately tiny: a Python web service with two endpoints.

- The **main endpoint** returns a short JSON greeting plus a version label.
- The **health endpoint** returns "ok" and nothing else.

Two design points that matter more than they look:

**The health endpoint has no dependencies.** It touches no database, calls
no other service. The orchestrator polls it every few seconds to decide
whether the application is alive. If it checked a database, a slow query
would make the orchestrator conclude the app was dead and kill a perfectly
healthy container — and the replacement would fail the same check, producing
a restart loop with a cause nowhere near the symptom.

**The version label is read from the environment, not hardcoded.** The same
image returns "dev" in dev and "prod" in production. This is the proof that
a deployment actually reached the environment you think it did, and it is
what makes one image usable across all three environments.

The app is small on purpose. A richer application would add hours of
debugging that teach nothing about delivery, and would obscure the parts
worth looking at.

---

## 3. The constraints that shaped every decision

Three constraints drove the architecture. Knowing them explains most of the
choices.

**No local tooling.** The development machine runs Windows Home, with no
container runtime and no cloud CLI installed, by choice. Consequence: the
CI pipeline is not just a quality gate, it is the *only* place anything can
run. This forced the pipeline to be built first rather than last, which
turned out to be an advantage — nothing could be written without also
writing the automation to execute it.

**The cloud account expires.** It is a time-limited free account that will
be closed by the provider on a fixed date, taking every resource with it.
Consequence: evidence of the working system is captured into the repository
as it happens. The repository is the portfolio; the cloud account is
temporary scaffolding.

**Effectively zero budget.** Consequence: two architectural choices are
deliberately not production-correct, and are documented as such rather than
hidden. Both are explained in section 7.

---

## 4. Day-by-day build log

### Day 1 — The container, and proving it works

**What we set out to do:** package the application so it runs identically
everywhere, and prove that claim rather than assert it.

**Why it matters first:** everything downstream deploys this artifact. There
is no point building infrastructure to run an image nobody has verified.

**How we did it:**

The application was packaged into a container image using a **multi-stage
build**. The first stage installs dependencies; the second stage starts from
a clean base and copies in only the finished dependencies, leaving the build
tooling behind. This keeps the shipped image smaller and removes tools an
attacker could use if they ever got inside.

The image runs as an **unprivileged user**, not as root. By default
containers run as root, which feels harmless because of the isolation — and
stops being harmless the moment that isolation is imperfect.

The application is served by a **production web server**, not the framework's
built-in development server. The development server handles one request at a
time and is explicitly not meant for production; shipping it is one of the
most common mistakes in this ecosystem.

Because nothing could be run locally, a CI pipeline was written on day one
to do the verification: build the image, start it, call both endpoints, and
**assert that the user inside the container is not root**. That last check is
the interesting one — "runs as non-root" is a claim everybody makes and
almost nobody tests. Here, if someone deletes that line from the container
definition, the build fails.

A vulnerability scanner was added in report-only mode, to establish a
baseline before making it blocking. Turning it strict on day one usually
means an immediate red build over something in the base image you cannot
fix, which trains people to ignore it.

**What it proves:** the artifact is reproducible, minimal, unprivileged and
verified by automation rather than by assertion.

---

### Day 2 — Foundations: state, identity, registry

This was the least visible day and the most important one. Nothing was
deployed. Three foundations were laid that everything else depends on.

#### Infrastructure as code, and the problem of state

All cloud infrastructure in this project is **declared in code** rather than
clicked together in a console. You describe what should exist; the tool works
out what to create, change or delete to make reality match.

The tool needs to remember which real resources it created — otherwise it
cannot tell "create this" apart from "this already exists, leave it alone."
That memory is called **state**.

State is the single most important operational concept here:

- If state lives on one laptop, automation cannot read it. A pipeline
  starting fresh would conclude nothing exists and try to create a second
  copy of everything.
- If state is lost, the tool forgets it owns anything, and you are deleting
  resources by hand in a console.
- If two people change infrastructure at once, their writes interleave and
  produce a state file describing a reality that never existed.

So state was moved to **shared cloud storage**, with versioning enabled (so a
bad write can be rolled back), encryption at rest (state can contain
secrets), and a **lock** so two simultaneous changes queue instead of
colliding.

#### The bootstrap problem

The storage holding the state is itself infrastructure. But the tool needs
that storage to exist *before* it can store anything. Chicken and egg.

Every team solves this the same way: the storage is created **once, by hand,
outside the automation**. It is the one resource allowed to be manual,
because it is the foundation everything else stands on. If the tool managed
the container holding its own memory, destroying the stack would delete the
record of how to destroy it.

#### Keyless authentication

The pipeline needs permission to change cloud infrastructure. The obvious
approach is to store an access key as a secret in the CI system.

That approach is how cloud accounts get compromised. Static keys never
expire on their own, they get copied into logs and scripts, and a leak is
often discovered months later.

Instead the pipeline uses **federated identity**. When a job runs, the CI
platform issues a short-lived, cryptographically signed token proving *which
repository, on which branch, in which workflow* is asking. The cloud provider
verifies that token and hands back temporary credentials that expire in about
an hour and cannot be replayed. **No long-lived key exists anywhere.**

Setting this up cost real time and taught two things worth remembering:

1. The identity token's subject field does not look like the documentation
   examples — the platform issues an internal, rename-proof identifier
   rather than the human-readable repository name. Trust rules written
   against the readable name silently never match, and the error message
   names neither the claim nor the rule that failed.
2. The cloud provider *refuses* a trust rule that does not constrain which
   workflow may assume the role. Scoping only by account or organisation is
   rejected outright — the provider forces you to be specific.

This is worth mentioning in an interview. It is the difference between having
configured something and having debugged it.

#### Separating what the pipeline may touch

The infrastructure is split into separate stacks, and the split is a security
boundary rather than tidiness:

- **Bootstrap** — the state storage, the identity provider, and the role the
  pipeline assumes. Applied by a human, once. The pipeline must never manage
  these. If the pipeline's own code owned the role the pipeline assumes,
  anyone able to merge a change could grant that role more permissions. That
  is privilege escalation with extra steps.
- **Shared** — things every environment uses. Applied by the pipeline.
- **Per-environment** — one stack per environment, each with its own separate
  state. This is a blast-radius boundary: a teardown command run against dev
  loads only dev's state, so it physically cannot see production's resources.
  Production is not protected by carefulness; it is invisible.

#### The image registry

A container registry was created to store built images.

**One registry shared by all environments, not one per environment.** This is
deliberate and it is the foundation of the whole promotion model: the exact
bytes tested in dev must be what reaches production. Separate registries
would mean copying or rebuilding between environments — and a rebuilt image
is a *different artifact*, so everything proved in dev would prove nothing
about production.

Two settings on the registry matter:

- **Tags are immutable.** Nobody can push a different image over an existing
  tag. Without this, the identifier in your deployment logs could point at
  code that is no longer there, and a rollback target could silently change
  underneath you.
- **Old images expire automatically.** Storage is limited and every merge
  adds another image. Without a cleanup rule this is a slow leak that
  surfaces weeks later as a surprise.

#### The gate itself

The pipeline was given its defining asymmetry:

- A **pull request** runs a *preview* — it reports exactly what would change,
  and changes nothing.
- A **merge** *applies* the change.

That asymmetry is the gate. Anyone can propose an infrastructure change;
nobody changes infrastructure without a merge. The preview is posted into the
run summary so a reviewer sees the infrastructure diff next to the code diff.

This matters more for infrastructure than for code, because some changes force
a resource to be **replaced** rather than updated. On a database, "replace"
means delete and recreate — empty. The preview is where you catch that. There
is no undo.

---

### Day 3 — The network

**What we set out to do:** build the private network the application will
run inside.

**How we did it:** a reusable network component was written describing an
isolated virtual network, two subnetworks placed in two separate physical
datacentres, a gateway to the internet, routing, and a firewall.

Concepts worth being able to explain:

**Two datacentres, not one.** One location means one failure domain. Two is
the minimum for anything claiming to survive a datacentre outage.

**A subnetwork is "public" because of its routing, not its name.** What makes
it public is a rule sending all non-local traffic to the internet gateway. A
subnetwork labelled "public" without that rule is a private subnetwork with a
misleading label. Forgetting the routing is one of the two classic causes of
"my server has a public address but nothing can reach it."

**The firewall is stateful.** A reply to an allowed incoming request is
automatically permitted, so there is no need to open extra ports for return
traffic. People who learned on the older stateless layer tend to over-open
rules out of habit.

**No remote-access port is open.** Opening the standard administrative port
to the internet is the most attacked surface in cloud computing, and it is
unnecessary — the cloud provider offers a session service that gives shell
access over an *outbound* connection, so there is no inbound port to attack
and no key material to lose. Access is controlled by identity policy and
logged centrally.

**It was written as a reusable component.** The network is described once and
instantiated separately for dev, staging and production with different
parameters. The alternative — copying the same description three times — means
that every future change has to be remembered in three places, and the
environments silently drift apart.

Also on this day, the pipeline was extended to **publish the image to the
registry** on merge. Until then, images were built, tested and thrown away
with the disposable machine that built them.

---

### Day 4 — Running it

**What we set out to do:** actually run the application on cloud
infrastructure.

#### Why an orchestrator rather than just a server

The naive approach is to start a server, connect to it, and run the container
by hand. That works for about a day, then:

- The container crashes at night. It stays dead.
- The server fails. Everything is gone until someone notices.
- Every deployment is a manual sequence of commands.
- Logs live inside a container on a machine you have to connect to.
- There is no record of what is *supposed* to be running, only what happens
  to be.

Every one of those makes a human the reliability mechanism.

A **container orchestrator** replaces that. You do not tell it to run a
container. You tell it **"one copy of this should always be running"** — and
it continuously makes that true. If the container dies it starts another. If
the machine dies it places the container elsewhere.

That shift — from issuing commands to declaring desired state — is the same
idea as infrastructure as code, applied to running processes instead of
cloud resources.

#### The pieces

- A **cluster** is a named pool of machines.
- A **container instance** is an ordinary server running a small agent that
  reports in and asks whether there is anything to run.
- A **task definition** is the recipe: which image, how much memory and CPU,
  which ports, which environment variables, how to health-check it. It is
  **versioned and immutable** — changing anything produces a new revision
  while the old one still exists, which is exactly what makes rollback
  possible.
- A **task** is one running container created from that recipe.
- A **service** is the supervisor. It runs a permanent loop comparing desired
  against actual and acting to close the gap. That loop is why a crashed
  container comes back without anyone being paged.

#### Two permission identities, easily confused

This is the part most people get wrong.

- One identity belongs to the **machine**, and lets its agent join the
  cluster and report status.
- A different identity is used by the **orchestrator itself**, before your
  container exists, to fetch the image from the registry and set up logging.

They are assumed by different actors at different moments. Swapping them
produces either a machine that boots fine and never joins the cluster, or a
container stuck waiting forever unable to fetch its image — and neither error
message mentions the identity.

A third kind exists for the application itself to call cloud APIs. This
application calls none, so it has none. Granting an identity that is not
needed is how least privilege quietly erodes.

#### Self-healing capacity

The server is created through a **scaling group** rather than directly, even
though only one is needed. If the machine dies, the group replaces it
automatically. A directly created server would simply stay dead.

#### Logs must leave the container

Container filesystems are disposable. When a container is replaced, anything
written inside it is gone. Logs are therefore streamed to a central logging
service while the container is alive, with an explicit retention period —
because the default is to keep them forever, which is a slow, invisible cost.

#### Deployment is asynchronous, and the pipeline accounts for it

When the infrastructure tool finishes, the orchestrator has only *accepted*
the new recipe. The new container may still be downloading, starting, or
crash-looping.

A pipeline that stopped there would report success while the deployment was
still failing. So the pipeline explicitly **waits for the service to reach a
steady state** before declaring the job green. That turns "deployed" from a
claim into something the pipeline verified.

#### Steady state is still not proof, so a smoke test was added

"The orchestrator is satisfied" and "the application is reachable" are
different statements. A wrong firewall rule, a missing route, or an
application listening on the wrong network interface would all leave the
orchestrator perfectly content while nothing outside could reach the service.

So a final step calls the running application **from outside the machine**,
retrying briefly to allow for startup, and fails the deployment if it does
not answer. It also asserts that the environment label in the response is the
expected one — which confirms configuration genuinely travelled from the
recipe into the running container, rather than the application falling back
to its built-in default.

The deployed address is printed into the job log rather than only into a
summary page. Summaries are easy to miss and impossible to search; logs are
where people actually look.

#### What was verified

The first successful deployment returned, over the public internet:

- HTTP 200
- A header identifying the production web server, confirming the framework's
  development server is not being used
- A JSON content type
- A body whose environment label read **dev**, where the application's own
  built-in fallback is a different value — proving the label could only have
  come from the deployment recipe

The console independently showed the expected server, its automatic
scaling group, its identity, its private address inside the second
subnetwork, and hardened instance metadata. Everything declared in code
existed in reality with the names the code gave it.

One incidental finding: the deployed address was unreachable from the
developer's own machine while working perfectly from inside the cloud
provider's network. The cause was the local internet connection blocking
outbound traffic on a non-standard port — nothing to do with the deployment.
The diagnostic that separated the two was the *speed* of the failure: a
firewall rule in the cloud silently drops packets and the request hangs for
about thirty seconds, whereas a local block is rejected instantly. That
distinction is a useful thing to know.

---

### Day 5 — Three environments, and the gate

**What we set out to do:** replicate the working environment into staging and
production, and put a human decision in front of production.

**Why this is the real test of the earlier work:** up to now there was one
environment, so the reusable components were reusable only in theory. Adding
two more either takes a few dozen lines each, or it does not — and if it does
not, the components were the wrong shape.

It took about sixty lines per environment. The network component and the
runtime component were both reused unchanged; only the parameters differ.

#### What actually differs between environments

Nothing about the application. Only configuration:

| | dev | staging | production |
|---|---|---|---|
| network range | 10.0 | 10.1 | 10.2 |
| servers / running copies | 1 / 1 | 1 / 1 | **2 / 2** |
| deployment style | stop, then start | stop, then start | **rolling** |
| log retention | 3 days | 7 days | 30 days |
| deploys automatically | yes | yes | **only after approval** |

Distinct network ranges are not strictly necessary today, since the three
networks are isolated and could all use the same addresses. They are distinct
because identical ranges cannot later be connected to each other — overlapping
addresses cannot be routed between — and because identical addresses in three
places make traffic logs ambiguous. Retrofitting this means rebuilding the
network, so it is decided at the start.

#### Production is the only one that deploys without downtime

Everywhere else, the running copy binds a fixed port on a single machine. Two
copies cannot hold the same port, so the old one must stop before the new one
starts: a few seconds of unavailability on every deployment.

Production runs two machines, so it can be told to keep at least half the
capacity serving at all times. One copy is drained and replaced, checked, and
only then is the other. Requests are served throughout.

This is worth being able to explain precisely, because the cause is not
obvious: the downtime elsewhere is a consequence of **port binding on a single
host**, not a limitation of the orchestrator. With a load balancer assigning
ports dynamically, even a single machine could deploy without downtime — which
is exactly what the load balancer we chose not to pay for would have bought.

#### The approval gate

Production waits for a human. The pipeline reaches it, stops, and shows a
reviewer prompt; nothing is applied until someone approves.

The important detail is **where that rule lives**. It is not a condition in
the pipeline code. It is configuration attached to the environment itself,
set by a human in the project settings.

That distinction is deliberate and is the same principle as keeping the
bootstrap layer outside what the pipeline may modify: **the thing that
controls access must not be modifiable by the thing it controls.** If the gate
were a line in the pipeline file, anyone able to change that file could remove
it. Because it lives on the environment, they cannot.

#### One deployment definition, called three times

The three deployments are identical in everything except which environment
they target. Rather than three near-identical copies, the deployment is
written once as a **reusable definition** and invoked three times with
different parameters.

The failure this avoids is specific and common: someone fixes a bug in the
development deployment, forgets to apply the same fix to staging and
production, and the environments quietly stop behaving the same way. At that
point testing in one says nothing about the others, which removes the entire
reason for having them.

#### A mistake worth recording

The first attempt failed before any job ran, with no checks appearing at all.
The cause: a reusable definition cannot grant itself permissions. Whatever it
requests is capped by whatever the caller allows, and the caller had allowed
nothing. Rather than quietly downgrading the request, the platform rejected
the whole file.

That rejection is the correct behaviour — a reusable definition pulled in from
elsewhere must not be able to escalate its own access. But it produced a
confusing symptom: a pull request showing **zero checks** alongside a green,
clickable merge button.

The lesson generalises: **zero checks never means everything passed.** It
means nothing ran, and something that reports nothing is far more dangerous
than something that reports a failure.

---

## 5. How a change flows through the system, end to end

1. A developer changes the application and opens a pull request.
2. The pipeline builds the image, runs it, calls both endpoints, checks it is
   not running as root, and scans it for known vulnerabilities.
3. In parallel, it previews the infrastructure change for every stack.
4. All checks green → the change can be merged. Any red → it cannot.
5. On merge, the image is published to the registry, tagged with the exact
   commit identifier that produced it.
6. Infrastructure is applied.
7. The environment's recipe is updated to point at the new image tag.
8. The orchestrator replaces the running container with one built from the
   new recipe.
9. The pipeline waits until the service is genuinely stable, then reports the
   address where it can be reached.

The two halves — **building the artifact** and **building the
infrastructure** — are independent tracks that meet at exactly one point: the
field in the recipe naming an image tag. That separation is why you can
redeploy without rebuilding, and rebuild without redeploying.

---

## 6. Decisions worth being able to defend

**Images are tagged with the commit identifier, never with a moving label
like "latest".** With a moving label you cannot answer "which version is in
production?", and a rollback has no target because the label has already
moved. A fixed identifier makes every deployment traceable to one commit and
rollback a deterministic operation.

**One registry, not one per environment.** So the tested bytes are the shipped
bytes.

**Configuration is injected at runtime, never baked into the image.** The
tempting alternative is building one image per environment with settings
compiled in — which destroys the promotion model, because you would be
testing one artifact and shipping a different one that has never been tested.

**Each environment has its own separate state.** Blast radius.

**The bootstrap layer is applied by a human, not the pipeline.** Otherwise
the pipeline can escalate its own permissions.

**Previews on proposal, changes only on merge.** The gate.

---

## 7. Two things deliberately done wrong, and why

Both are cost decisions. Being able to explain them is more valuable than
having quietly avoided them.

**Servers are in publicly routable subnetworks.** Production systems place
application servers in private subnetworks that reach the internet through a
managed translation gateway. That gateway costs roughly thirty dollars a
month and is never free. The trade-off: our servers are directly reachable
from the internet, protected only by firewall rules, rather than being
unreachable by design.

**There is no load balancer.** A load balancer costs roughly sixteen dollars
a month. Without one there is no encrypted endpoint, no stable address, no
path-based routing, and — most visibly — **no zero-downtime deployment**.
Because the container binds a fixed port on a single machine, and two
containers cannot hold the same port, the old container must stop before the
new one starts. Every deployment therefore has a few seconds of downtime. A
load balancer with dynamically assigned ports would remove that entirely.

Both are recorded in the architecture notes rather than hidden, which is the
point: an engineering trade-off you can name and justify is a different thing
from an oversight.

---

## 8. Where the project stands

**Working end to end today.** A change merged to the main branch is built
into an image, tested, scanned, published to the registry tagged with its
commit, and deployed to the dev environment on real cloud infrastructure —
with no human running a command at any point. The pipeline then waits for the
orchestrator to stabilise and calls the running application to confirm it
serves traffic.

Built and verified so far:

- The application, containerised, minimal, running unprivileged, with that
  last property enforced by a test rather than by documentation.
- A pipeline that builds, runs, tests and scans the image on every proposed
  change, and publishes it only on merge.
- Remote, versioned, encrypted, locked infrastructure state.
- Keyless authentication from the pipeline to the cloud, with no long-lived
  credentials anywhere.
- A bootstrap layer deliberately outside what the pipeline may modify.
- A shared image registry with immutable tags and automatic cleanup.
- A reusable network component, and a reusable runtime component.
- One fully working environment, reachable over the internet.

Still ahead:

- Replicate the environment into staging and production, which is the test of
  whether the reusable components are genuinely reusable.
- Add the human approval gate before production. This is the feature the
  project is named for.
- Add unit tests to the proposal gate, and automatic rollback when a
  post-deployment test fails.
- Add a step that summarises each change in plain English for reviewers.
- Tighten the pipeline's cloud permissions from broad to minimal.
- Phase two: migrate the same application and the same pipeline onto
  Kubernetes, reusing the concepts rather than relearning them — the recipe
  becomes a deployment, the supervisor loop is the same loop.

---

## 9. Explaining this in an interview

A structure that works:

**Open with the problem, not the tools.** "I wanted to build a delivery
pipeline where nothing reaches production by hand, but production still
requires a human decision."

**Describe the flow, not the file layout.** Walk through what happens between
a developer opening a pull request and the change being live.

**Lead with the security decisions.** No long-lived cloud credentials
anywhere; the pipeline authenticates with short-lived federated tokens. The
bootstrap layer is deliberately outside what the pipeline can modify, so the
pipeline cannot grant itself more access. Containers run unprivileged, and
that is enforced by a test rather than by documentation.

**Have one debugging story ready.** The federated identity setup is the
strongest one: the trust rule silently never matched because the identity
token uses internal, rename-proof identifiers rather than the human-readable
names every tutorial shows, and the error message named neither the claim nor
the rule that failed.

**Name the trade-offs before you are asked.** Publicly routable subnetworks
instead of a translation gateway; no load balancer, therefore brief downtime
on deployment. Say what it costs and what you would change with a budget.

**Expect these questions:**

- *What is state and why does it matter?* — Section 2, Day 2.
- *How do you prevent two deployments colliding?* — Locking, plus the
  pipeline queues rather than cancelling, because killing a change midway
  leaves resources created but unrecorded.
- *How do you roll back?* — Recipes are versioned and immutable, and images
  are tagged by commit. Rollback is redeploying a previous tag.
- *Why one registry for all environments?* — So the tested artifact is the
  shipped artifact.
- *What happens if the server dies?* — The scaling group replaces it and the
  orchestrator reschedules the container.
- *Why not Kubernetes?* — Phase two. Then explain what an orchestrator does
  in general, and that the concepts transfer directly.
