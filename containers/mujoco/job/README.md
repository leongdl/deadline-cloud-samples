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
   the [troubleshooting appendix](#appendix-troubleshooting) below — this is the step most likely to
   be missing.

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

## Appendix: troubleshooting

Everything below was hit while getting this job to run. Each row is problem, fix, and the command
that identifies it — the diagnostic matters most, because several of these report something
misleading.

| Problem | Fix | How to find it |
|---|---|---|
| Session fails instantly, `processExitCode: 0`, `Log provisioning error: ResourceNotFoundException`. Nothing reaches the log. | Create the log group `/aws/deadline/<farm-id>/<queue-id>`. | `aws logs describe-log-groups --log-group-name-prefix /aws/deadline/<farm-id>/<queue-id>` returns `[]`. |
| `Value at 'logStreamName' failed to satisfy constraint: Member must not be null` | Same root cause as the row above — not a separate bug. Fix the log group and the role, and this goes away. | Check for the log-provisioning failure first, on the `syncInputJobAttachments` action. |
| Sessions fail before running anything, log group *does* exist. | Add `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` to the queue role, on `arn:aws:logs:<region>:<account>:log-group:/aws/deadline/<farm-id>/*` and its `:log-stream:*`. | Dump the queue role's policies and grep for `logs:`. Only `logs:GetLogEvents` means writes are missing. |
| Every task dies at `docker pull`. | Give the queue role ECR read: `ecr:GetAuthorizationToken` on `*`, plus `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability` on the one repository. | Grep the queue role's policies for `ecr:`. The task calls `aws ecr get-login-password` as the *queue* role, not the fleet role. |
| Workers reach `CREATED` and never `STARTED`. `Could not sts:AssumeRole ... allows sts:AssumeRole by credentials.deadline.amazonaws.com` | Fix the fleet role's trust policy, or point the fleet at the standard `AWSDeadlineCloudFleetRole-*`. | `aws deadline get-fleet` for `roleArn`, then check that role's trust policy. Job-side debugging is a dead end here. |
| Tasks sit `READY` forever, no sessions ever appear. | Associate the fleet with the queue. | `aws deadline list-queue-fleet-associations --farm-id <f> --queue-id <q>` is empty. |
| `docker: command not found`, or permission denied on the docker socket. | Fleet host configuration needs `dnf install docker -y`, `systemctl start docker`, `usermod -aG docker job-user`. | `aws deadline get-fleet --query hostConfiguration.scriptBody`. Note a trailing `exit 0` with no `set -e` makes the script report success even when docker never installed. |
| Job succeeds but no output downloads. | The container must not write as root: `docker run --user "$(id -u):$(id -g)"`. | `ls -la` the output dir in the session log. Root-owned files cannot be read by the attachment upload. |
| `docker pull` fails only inside the task, though the host config logged in fine. | Log in again inside the step script. | Host config runs as root and writes `/root/.docker/config.json`; the task runs as `job-user` and does not inherit it. |

### Triage order

1. `aws deadline get-job` — is it `READY` (nothing picked it up) or are tasks `FAILED`?
2. `aws deadline list-sessions` — no sessions means scheduling or fleet, not your script.
3. `aws deadline list-session-actions` — which action failed, and was it the job's or the queue's?
4. `aws deadline get-session-action` — `progressMessage` carries the real reason. `processExitCode: 0`
   on a failed action means the session never got as far as your code.
5. Only then read the session log in CloudWatch.
