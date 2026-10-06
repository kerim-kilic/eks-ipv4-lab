# eks-ipv4-lab

[![Checks](https://github.com/kerim-kilic/eks-ipv4-lab/actions/workflows/checks.yml/badge.svg)](https://github.com/kerim-kilic/eks-ipv4-lab/actions/workflows/checks.yml)

A small, short-lived lab that runs an EKS cluster out of IPv4 addresses on purpose, then tries the fixes one at a time:
tuning the warm pool, prefix delegation, and a secondary `100.64.0.0/16` range for pods. It goes with an article on
[kerim-kilic.com](https://kerim-kilic.com/articles/), published on 7 November 2026.

Everything is built in one sitting and destroyed at the end. The captured output from my own run is in
[`captures/scrubbed/`](captures/scrubbed/), with account, resource and public address details replaced. Steps 1 to 3
ran on one cluster; steps 4 and 3b ran later the same day on a fresh one, after the pod subnets got their own route table.

> **This costs money while it runs.** An EKS control plane, four `t3.medium` nodes and two NAT gateways with their
> public addresses come to about $0.37 an hour in `us-east-1` (October 2026), plus a little for storage and data. Check
> current prices, set a budget alert first, and destroy everything when you're done.

## What it builds

A VPC deliberately too small for its cluster:

| Range | Use |
|---|---|
| `10.20.0.0/27`, `10.20.0.32/27` | Private subnets: control plane ENIs, nodes and, by default, pods (27 usable addresses each) |
| `10.20.0.64/28`, `10.20.0.80/28` | Public subnets: one NAT gateway each |
| `100.64.0.0/19`, `100.64.32.0/19` | Pod subnets, step 4 only, tagged `kubernetes.io/role/cni`, with a route table of local routes only |

An EKS cluster with a managed node group of four `t3.medium` nodes across two Availability Zones: 3 ENIs with 6 IPv4
addresses each, so a full node holds 18 addresses and two of them are more than a private subnet has. The VPC CNI, CoreDNS
and kube-proxy are EKS add-ons, and the CNI settings for each step are in Terraform
([`terraform/steps/`](terraform/steps/)), not in a `kubectl set env`.

Each step gets a new node group, so no CNI state carries over from the step before.

## Requirements

- An AWS account you can make a mess in, **not** one that runs anything you care about, with an AWS Budgets alert.
- Terraform 1.11 or later, the AWS CLI v2, `kubectl`, `jq` and Python 3.
- An AWS CLI profile for that account. The scripts use `eks-lab` unless `AWS_PROFILE` says otherwise.

## Running it

```sh
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # then fill it in
export AWS_PROFILE=eks-lab
scripts/preflight.sh                                              # right account? budget? EKS default version?

terraform -chdir=terraform init
terraform -chdir=terraform plan -var-file=steps/1-default.tfvars
terraform -chdir=terraform apply -var-file=steps/1-default.tfvars  # about 15 minutes
scripts/kubeconfig.sh
```

Then for each step:

```sh
terraform -chdir=terraform apply -var-file=steps/<step>.tfvars
scripts/fill.sh            # scales a deployment of pause pods until the nodes are full, measuring as it goes
```

`fill.sh` takes the number of pods to add per round and the seconds to wait before measuring (default `5 45`). Once
pods start failing, it stops after three rounds without a single extra pod running, so a step where nothing fits
doesn't run for an hour.

| Step | File | What changes |
|---|---|---|
| 1 | `1-default.tfvars` | Nothing: the CNI keeps a spare ENI's worth of addresses on every node |
| 2 | `2-warm-ip.tfvars` | `WARM_IP_TARGET=2`, `MINIMUM_IP_TARGET=5`: a few spare addresses instead of a spare ENI |
| 3 | `3-prefix.tfvars` | Prefix delegation: a `/28` per ENI slot, and the kubelet allowed 110 pods |
| 4 | `4-pod-subnets.tfvars` | Default settings again, plus the `100.64.0.0/16` range with subnets tagged for the CNI |
| 3b | `3b-prefix-pod-subnets.tfvars` | Prefix delegation with the step 4 pod subnets, and the kubelet allowed 60 pods (run after step 4) |

After step 4, `scripts/egress-check.sh` fills the nodes' primary ENIs with pause pods, then starts a few pods that ask an
external service which address they come from. They have `100.64` addresses, and the internet sees the NAT gateway. It
also saves the node's SNAT rules and policy routing (`ip rule`). The pod subnets' route table has only local routes, so
the check passing shows that this traffic leaves through the node's primary interface, in a private subnet.

### What gets measured

`scripts/fill.sh` writes `captures/raw/<step>/fill.csv`, one row per scale-up:

| Column | Meaning |
|---|---|
| `replicas`, `running` | Pause pods asked for, and running |
| `ip_failures` | Pods whose sandbox failed because the CNI had no address to give |
| `unschedulable` | Pods the scheduler couldn't place, because the nodes are at max pods |
| `pods_in_pod_cidr` | Pods with a `100.64` address (step 4) |
| `node_subnet_free`, `pod_subnet_free` | Free addresses left in those subnets, according to EC2 |
| `cni_total_ips`, `cni_assigned_ips` | Addresses the CNI holds on all nodes, and how many of them pods use |
| `enis_in_node_subnets` | Network interfaces in the node subnets |

It also saves full snapshots (nodes, pods, events, the CNI's settings and metrics, subnets, route tables and ENIs)
before filling, at the first IP failure, and at the end. At the first failure and at the end, `scripts/logs.sh` adds the
logs: `kubectl describe` for the nodes and for a pod that couldn't get an address, the `aws-node` container logs, and
each node's `ipamd.log` and `plugin.log`, read through a node debug pod. At the end it scales the pause pods to 0 first,
because a node at max pods has no room for the debug pod.

## Publishing the output

Raw output in `captures/raw/` is git-ignored: it holds account IDs, resource IDs and public addresses.
`scripts/scrub.py` copies it to `captures/scrubbed/` with each of those replaced by a stable placeholder
(`subnet-EXAMPLE1`, `203.0.113.1`, ...) and refuses to finish cleanly if anything that looks like an account ID is
left. Private addresses stay, because they're what the lab is about.

The node logs from the end of each step (`2-full/logs/ipamd-*.log.gz` and `cni-plugin-*.log.gz`) are gzipped: they
are mostly the CNI retrying the same request every few seconds, and `zcat` reads them. They include everything in the
first-failure logs, which stay plain text so you can read them here. The last minutes of each full log are the pause
pods being removed, because `logs.sh` has to make room on the nodes before it can read the logs.

## Tearing down

```sh
kubectl delete deployment pause --ignore-not-found
terraform -chdir=terraform destroy -var-file=steps/<last step>.tfvars
scripts/check-teardown.sh   # no cluster, instances, NAT gateway, Elastic IP, load balancer or stray ENI left
```

Deleting the pause pods first lets the CNI give its addresses back before the nodes go, which avoids ENIs that keep a
subnet from being deleted. Then delete the access key you used, if it was a temporary one.

## Checks

Every push and pull request runs [`checks.yml`](.github/workflows/checks.yml): Terraform formatting and validation,
TFLint with the AWS ruleset, ShellCheck on the scripts, and actionlint on the workflow. None of them need AWS
credentials. To run the same checks locally:

```sh
terraform fmt -check -recursive terraform
terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate
tflint --init --chdir=terraform && tflint --chdir=terraform
shellcheck scripts/*.sh
actionlint   # or: docker run --rm -v "$PWD:/repo" --workdir /repo rhysd/actionlint:1.7.12
```

## Shortcuts taken

This is a lab, not a reference architecture:

- the CNI's IAM policy is on the node role, not on the `aws-node` service account through EKS Pod Identity or IRSA;
- local Terraform state;
- the cluster endpoint is public, limited to the addresses in `admin_cidrs`.

## Licence

[MIT](LICENSE)
