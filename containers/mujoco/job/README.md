# MuJoCo hand sweep as a Deadline Cloud job bundle

Submits the Shadow Hand parameter sweep to a Deadline Cloud queue. Each task runs one parameter
combination inside the [`rocky9-cpu`](../rocky9-cpu/) image on a fleet worker, and job attachments
bring the frames, MP4 and GIF back to your machine.

This is the farm counterpart of [`../templates/`](../templates/), which runs the same sweep locally
through the `openjd` CLI. The simulation and the 2x2 parameter space are identical; only the
delivery differs.

| | `../templates/` (local) | `job/` (farm) |
|---|---|---|
| Runs on | your workstation | fleet workers |
| Container invoked by | a `WRAP_ACTIONS` environment | the step script directly |
| Image comes from | your local docker | ECR |
| Output returned by | a bind mount | job attachments |

The farm job puts `docker run` in the step script rather than using `WRAP_ACTIONS`, because the
wrap environment is a local convenience. On a farm the equivalent would be a queue environment
supplied by the farm, which is the same mechanism applied at a different scope.

## Prerequisites

1. **The image in ECR.** Build it and push:

   ```console
   cd ../rocky9-cpu
   docker build --platform linux/amd64 -t mujoco-rocky9 .

   ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
   REGION=us-west-2
   REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
   aws ecr create-repository --repository-name mujoco-rocky9 --region "$REGION"
   aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
   docker tag mujoco-rocky9:latest "$REGISTRY/mujoco-rocky9:latest"
   docker push "$REGISTRY/mujoco-rocky9:latest"
   ```

   `submit.sh` checks the image exists in ECR and refuses to submit otherwise — otherwise every task
   fails on `docker pull` after the fleet has already scaled up.

2. **Docker on the fleet.** The worker needs a docker daemon and `job-user` in the `docker` group.
   Put this in the fleet's host configuration script:

   ```bash
   dnf install docker -y
   systemctl start docker
   usermod -aG docker job-user
   ```

3. **Queue role permissions.** The task calls `aws ecr get-login-password` with the *queue role*, so
   that role needs ECR read and CloudWatch log-stream writes. See
   [Queue role permissions](#queue-role-permissions) below — this is the step most likely to be
   missing.

## Submit

```console
FARM_ID=farm-xxxxxxxx QUEUE_ID=queue-xxxxxxxx ./submit.sh
```

Then watch it and pull the output down:

```console
aws deadline get-job    --farm-id "$FARM_ID" --queue-id "$QUEUE_ID" --job-id "$JOB_ID"
aws deadline list-sessions --farm-id "$FARM_ID" --queue-id "$QUEUE_ID" --job-id "$JOB_ID"
deadline job download-output --farm-id "$FARM_ID" --queue-id "$QUEUE_ID" --job-id "$JOB_ID"
```

Overrides: `DOCKER_REPO`, `DOCKER_TAG`, `ECR_REGISTRY`, `DURATION`, `FPS`, `MAX_FAILED`,
`AWS_DEFAULT_REGION`.

## Output

`deadline job download-output` writes into `./output/`, one directory per combination — 43 files
each, 172 in total for the 2x2:

```text
output/damp4.0-kp2.0/
├── frames/damp4.0-kp2.0-0000.png   ... 0039.png
├── clip.mp4
├── preview.gif
└── metrics.json
```

`OutputDir` is a `PATH` parameter with `objectType: DIRECTORY` and `dataFlow: OUT`, which is what
makes job attachments upload it from the worker and reassemble it locally.

## Verified run

Submitted to a service-managed Linux spot fleet (8–32 vCPU, max 3 workers), 4 tasks across 3
workers, 2 simulated seconds per combination at 20 fps:

```
lifecycleStatus  CREATE_COMPLETE
taskRunStatus    SUCCEEDED
tasks            READY 0 / RUNNING 0 / SUCCEEDED 4 / FAILED 0
```

Artifacts downloaded and checked — every GIF parsed for real frame blocks, not just a size check:

| Combination | Frames | MP4 bytes | GIF bytes | GIF images | Codec | Clip |
|---|---|---|---|---|---|---|
| `damp0.5-kp0.5` | 40 | 284,166 | 2,099,189 | 40 | libopenh264 | 2.0 s |
| `damp0.5-kp2.0` | 40 | 287,707 | 2,106,838 | 40 | libopenh264 | 2.0 s |
| `damp4.0-kp0.5` | 40 | 254,114 | 2,112,301 | 40 | libopenh264 | 2.0 s |
| `damp4.0-kp2.0` | 40 | 275,636 | 2,074,207 | 40 | libopenh264 | 2.0 s |

The session log confirms the container path end to end: `Running Session Actions as user: job-user`,
`Login Succeeded`, then `Pulling .../mujoco-rocky9:latest`.

## Queue role permissions

The step script runs as the queue's role, so that role needs more than the default. Both gaps below
produced failures that pointed somewhere unhelpful, so they are worth checking before submitting.

**ECR read.** Without it, `aws ecr get-login-password` fails and every task dies at the pull. Scope
it to the one repository rather than attaching `AmazonEC2ContainerRegistryFullAccess`:

```json
{ "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
{ "Effect": "Allow",
  "Action": ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage",
             "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"],
  "Resource": "arn:aws:ecr:<region>:<account>:repository/mujoco-rocky9" }
```

**CloudWatch log-stream writes.** Without these the session fails *before running anything*, with
`Log provisioning error: ResourceNotFoundException` on the `syncInputJobAttachments` action and
`processExitCode: 0`. Nothing reaches the log, because the log is what failed:

```json
{ "Effect": "Allow",
  "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
  "Resource": ["arn:aws:logs:<region>:<account>:log-group:/aws/deadline/<farm-id>/*",
               "arn:aws:logs:<region>:<account>:log-group:/aws/deadline/<farm-id>/*:log-stream:*"] }
```

The session's log group, `/aws/deadline/<farm-id>/<queue-id>`, must also exist. Deadline Cloud
normally creates it with the queue; if it is missing, create it explicitly, because
`CreateLogStream` against an absent group is what raises that `ResourceNotFoundException`.

A follow-on symptom is worth recognising: once provisioning fails, later calls pass no stream name
and you get `Value at 'logStreamName' failed to satisfy constraint: Member must not be null`. That
is the same root cause, not a second problem.

## Other failure modes seen

**Fleet role trust policy.** Workers that reach `CREATED` and never become `STARTED`, with
`Could not sts:AssumeRole ... Please check its trust policy to verify that it allows sts:AssumeRole
by credentials.deadline.amazonaws.com`, are a fleet-role problem, not a job problem. Check the
fleet's `roleArn` trust policy.

**No queue-fleet association.** Tasks sit `READY` forever with no sessions. Check
`aws deadline list-queue-fleet-associations`.

**Root-owned output.** The step passes `docker run --user "$(id -u):$(id -g)"`. Without it the
container writes as root and the attachment upload cannot read the files back.
