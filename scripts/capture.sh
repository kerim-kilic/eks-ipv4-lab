#!/usr/bin/env bash
# Saves a full snapshot of the cluster and the VPC to captures/raw/<step>/<label>/.
# Usage: scripts/capture.sh <label>
source "$(dirname "$0")/env.sh"

label=${1:?usage: capture.sh <label>}
step=$(tf_out step)
region=$(lab_region)
out="$RAW_DIR/$step/$label"
mkdir -p "$out"

log "Capturing $step/$label"

kubectl get nodes -o wide >"$out/nodes.txt"
kubectl get nodes -o json |
  jq -r '.items[] | [.metadata.name, .metadata.labels["node.kubernetes.io/instance-type"], .metadata.labels["topology.kubernetes.io/zone"], .status.allocatable.pods] | @tsv' \
    >"$out/node-max-pods.tsv"
kubectl get pods -A -o wide >"$out/pods.txt"
kubectl get events -A --sort-by=.lastTimestamp >"$out/events.txt"
kubectl get events --field-selector reason=FailedCreatePodSandBox -o json |
  jq -r '.items[].message' | sort | uniq -c | sort -rn >"$out/sandbox-failures.txt"

# What the CNI is actually running with, and which add-on version.
kubectl -n kube-system get daemonset aws-node -o json |
  jq '.spec.template.spec.containers[] | select(.name == "aws-node") | {image, env: [.env[] | select(.value != null) | {(.name): .value}] | add}' \
    >"$out/aws-node.json"
aws eks describe-addon --region "$region" --cluster-name "$(tf_out cluster_name)" --addon-name vpc-cni \
  --query 'addon.{version: addonVersion, configuration: configurationValues}' >"$out/vpc-cni-addon.json"

for pod in $(kubectl -n kube-system get pods -l k8s-app=aws-node -o jsonpath='{.items[*].metadata.name}'); do
  node=$(kubectl -n kube-system get pod "$pod" -o jsonpath='{.spec.nodeName}')
  kubectl get --raw "/api/v1/namespaces/kube-system/pods/$pod:61678/proxy/metrics" 2>/dev/null |
    grep -E '^awscni_(total_ip_addresses|assigned_ip_addresses|eni_allocated|eni_max|ip_max|ipamd_error_count|no_available_ip_addresses|aws_api_error_count)' \
      >"$out/cni-metrics-$node.txt" || true
done

aws ec2 describe-subnets --region "$region" --filters "Name=vpc-id,Values=$(tf_out vpc_id)" \
  --query 'Subnets[].{Name: Tags[?Key==`Name`]|[0].Value, Cidr: CidrBlock, Zone: AvailabilityZone, Free: AvailableIpAddressCount}' \
  --output table >"$out/subnets.txt"

# Every route table in the VPC: which subnets use it and where its routes lead.
aws ec2 describe-route-tables --region "$region" --filters "Name=vpc-id,Values=$(tf_out vpc_id)" \
  --query 'RouteTables[].{Name: Tags[?Key==`Name`]|[0].Value, Subnets: join(`, `, Associations[].SubnetId || `[]`), Routes: join(`; `, Routes[].join(` -> `, [DestinationCidrBlock || ``, GatewayId || NatGatewayId || TransitGatewayId || `?`]))}' \
  --output table >"$out/route-tables.txt"

# Every ENI in the VPC: who owns it, how many addresses and prefixes it holds.
aws ec2 describe-network-interfaces --region "$region" --filters "Name=vpc-id,Values=$(tf_out vpc_id)" \
  --query 'NetworkInterfaces[].{Subnet: SubnetId, Type: InterfaceType, Description: Description, Instance: Attachment.InstanceId, DeviceIndex: Attachment.DeviceIndex, Addresses: length(PrivateIpAddresses), Prefixes: length(Ipv4Prefixes || `[]`)}' \
  --output table >"$out/enis.txt"

log "Saved to ${out#"$REPO_ROOT"/}"
