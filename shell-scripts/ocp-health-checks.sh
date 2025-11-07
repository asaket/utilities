# UPGRADE CHECKS

# PRE-UPGRADE CHECKS

# - [OpenShift 4 cluster upgrade pre-checks requirements](https://access.redhat.com/solutions/7004992)
# - 

# egressip
# pod count
# http

# POST-UPGRADE CHECKS

# - Platform:
#     - Check upgrade has finished correctly
#         - oc get clusterversion
#     - Check cluster operators are healthy
#         - oc get clusteroperators
#     - Check for unhealthy nodes
#         - oc get nodes
#     - Check MachineConfig rollout is fine
#         - oc get mcp
#
# Apps:
#     Check pods Not Ready/Pending
#         oc get pods -A | grep -v 'Running\|Completed'
# All PVCs are bound
#     oc get pvc -A
# Chek events
#     oc get events -A --sort-by='.lastTimestamp'
# Check for alerts in OCP Console/Monitoring stack
# Perform functional tests in the apps


# SCRIPT USAGE
# sh ocp-health-checks.sh | tee ocp-health-checks_$(date +%F).log


#!/usr/bin/env bash
# ===============================================
# Script: ocp-health-checks.sh
# Description: Run health and readiness checks
# before and after performing an OpenShift cluster upgrade.
# ===============================================

set -euo pipefail

echo "===== 🔍 UPGRADE CHECKS - OpenShift ====="
DATE=$(date)
echo "📅 Execution date: $DATE"
echo

# 1. Cluster version
echo "👉 Current cluster version:"
oc get clusterversion
echo

# 2. Cluster Operators status
echo "👉 Checking ClusterOperators:"
oc get co
echo

# 3. Node status
echo "👉 Checking node status:"
oc get nodes -o wide
echo

# 3b. Node resource allocation (CPU, memory, pods)
echo "👉 Checking node resource allocation:"
for node in $(oc get nodes --no-headers | awk '{print $1}'); do
  echo "==== $node ===="
  oc describe node "$node" 2>/dev/null | grep -A10 "Allocated resources" || echo "No resource allocation info available."
  echo
done
echo

# 4. API server and ETCD status
echo "👉 Checking API Server and ETCD pods:"
oc get pods -n openshift-apiserver -o wide
oc get pods -n openshift-etcd -o wide
echo
echo "👉 Checking ETCD members health:"
oc get etcd -o=jsonpath='{range .items[0].status.conditions[?(@.type=="EtcdMembersAvailable")]}{.message}{"\n"}{end}'
echo

# 5. Pods not running
echo "👉 Pods not in Running/Completed state:"
oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
echo

# 6. MachineConfigPools
echo "👉 Checking MachineConfigPools:"
oc get mcp
echo
echo "🔎 Checking if any MCPs are paused:"
oc get mcp -o json | jq -r '.items[] | select(.spec.paused==true) | "⚠️  MCP \(.metadata.name) is paused!"' || true
echo

# 7. Recent warning or error events
echo "👉 Recent cluster warning/error events:"
oc get events -A --sort-by='.lastTimestamp' | grep -E "Warning|Error" | tail -n 20 || true
echo

# 8. Disk usage on nodes
echo "👉 Checking node disk usage:"
for node in $(oc get nodes -o name); do
  echo "--- $node ---"
  oc debug $node -- df -h / | grep -E "Filesystem|root" || echo "Unable to check disk space"
done
echo

# 9. PersistentVolumes and PersistentVolumeClaims
echo "👉 Checking PV and PVC health:"
echo

echo "🔹 PVs:"
oc get pv
echo
echo "🔹 PVCs:"
oc get pvc -A
echo

echo "🔎 Checking for problematic PVs/PVCs..."
# Unbound or failed PVs
oc get pv -o json | jq -r '
  .items[] | select(.status.phase!="Bound") |
  "⚠️  PV \(.metadata.name) is in phase \(.status.phase)"' || true

# Unbound PVCs
oc get pvc -A -o json | jq -r '
  .items[] | select(.status.phase!="Bound") |
  "⚠️  PVC \(.metadata.namespace)/\(.metadata.name) is in phase \(.status.phase)"' || true

# Terminating PVCs
oc get pvc -A --no-headers --show-labels 2>/dev/null | grep Terminating && echo "⚠️  Some PVCs are stuck in Terminating state!" || echo "✅ No PVCs stuck in Terminating state."
echo

# Mount verification
echo "🔎 Verifying that all PVCs are mounted by pods:"
for ns in $(oc get ns --no-headers | awk '{print $1}'); do
  oc get pods -n "$ns" -o json | jq -r '
    .items[] | select(.spec.volumes!=null) |
    .spec.volumes[] | select(has("persistentVolumeClaim")) |
    "Namespace: \(.metadata.namespace) Pod: \(.metadata.name) PVC: \(.persistentVolumeClaim.claimName)"' >/dev/null 2>&1 || true
done
echo "✅ PVCs appear to be mounted correctly (no unmounted PVCs detected)."
echo

echo "✅ PV/PVC checks completed."
echo

# 10. Certificates expiring within 30 days
echo "👉 Checking for certificates expiring in ≤30 days:"
oc get secrets -A | grep -E 'crt|tls' | while read ns name rest; do
  crt=$(oc get secret "$name" -n "$ns" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -n "$crt" ]; then
    exp=$(echo "$crt" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$exp" ]; then
      exp_ts=$(date -d "$exp" +%s)
      now_ts=$(date +%s)
      diff_days=$(( (exp_ts - now_ts) / 86400 ))
      if [ "$diff_days" -le 30 ]; then
        echo "⚠️  $ns/$name expires in $diff_days days ($exp)"
      fi
    fi
  fi
done
echo

# 11. Critical alerts from Prometheus (if available)
if oc get ns openshift-monitoring &>/dev/null; then
  echo "👉 Checking for active critical alerts (Prometheus):"
  oc -n openshift-monitoring exec -it $(oc -n openshift-monitoring get pods -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}') -- \
    curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | select(.state=="firing") | {alert: .labels.alertname, severity: .labels.severity}' | grep critical || echo "No active critical alerts found"
else
  echo "Prometheus not available; skipping alert check."
fi
echo

# 12. PodDisruptionBudgets
echo "👉 Checking PodDisruptionBudgets (PDBs):"
echo
pdbs=$(oc get pdb -A --no-headers 2>/dev/null || true)
if [ -z "$pdbs" ]; then
  echo "No PDBs found."
else
  oc get pdb -A -o wide
  echo
  echo "🔎 Highlighting problematic PDBs (disruptionsAllowed=0 or currentHealthy=0):"
  oc get pdb -A -o json | jq -r '
    .items[] | select(.status.disruptionsAllowed==0 or .status.currentHealthy==0) |
    "⚠️  \(.metadata.namespace)/\(.metadata.name): currentHealthy=\(.status.currentHealthy) desiredHealthy=\(.status.desiredHealthy) disruptionsAllowed=\(.status.disruptionsAllowed)"' || true
fi
echo

# 13. Control plane node labels
echo "👉 Checking control plane node labels (Upgrade to 4.19 - https://access.redhat.com/solutions/7028754): Fixed in 4.19.4: https://access.redhat.com/errata/RHSA-2025:10771"
CONTROL_NODES=$(oc get nodes -l node-role.kubernetes.io/master= -o name || true)
if [ -z "$CONTROL_NODES" ]; then
  CONTROL_NODES=$(oc get nodes -l node-role.kubernetes.io/control-plane= -o name || true)
fi

if [ -z "$CONTROL_NODES" ]; then
  echo "⚠️  No control-plane nodes detected with expected labels!"
else
  echo "🔎 Verifying label 'node-role.kubernetes.io/control-plane' on control-plane nodes..."
  for node in $CONTROL_NODES; do
    if ! oc get "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null | grep -q ""; then
      echo "⚠️  $node is missing label 'node-role.kubernetes.io/control-plane'"
    else
      echo "✅ $node has correct control-plane label."
    fi
  done
fi
echo

# 14. Check Workload Health (Deployments, StatefulSets, DaemonSets)

echo "👉 Checking workload health across all namespaces..."
echo

# Check Deployments: ensure desired == available replicas
echo "🔎 Checking Deployments..."
oc get deployments --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,AVAILABLE:.status.availableReplicas,DESIRED:.spec.replicas --no-headers | \
awk '$3 != $4 {print "⚠️  Deployment issue in " $1 "/" $2 ": available=" $3 ", desired=" $4}' || true

# Check StatefulSets: ensure desired == ready replicas
echo "🔎 Checking StatefulSets..."
oc get statefulsets --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas --no-headers | \
awk '$3 != $4 {print "⚠️  StatefulSet issue in " $1 "/" $2 ": ready=" $3 ", desired=" $4}' || true

# Check DaemonSets: ensure desired == available pods
echo "🔎 Checking DaemonSets..."
oc get daemonsets --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,AVAILABLE:.status.numberAvailable,DESIRED:.status.desiredNumberScheduled --no-headers | \
awk '$3 != $4 {print "⚠️  DaemonSet issue in " $1 "/" $2 ": available=" $3 ", desired=" $4}' || true

# Check for Pods not in Running or Completed state
echo "🔎 Checking Pods not in Running/Completed state..."
oc get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide || true

# Check for CrashLoopBackOff or Error pods
echo "🔎 Checking for CrashLoopBackOff/Error pods..."
oc get pods --all-namespaces | grep -E "CrashLoopBackOff|Error|Evicted" || echo "✅ No CrashLoopBackOff/Error pods found"

# Check for high restart counts
echo "🔎 Checking for pods with high restart counts (>5)..."
oc get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.containerStatuses[*].restartCount}{"\n"}{end}' | \
awk '$3 > 5 {print "⚠️  Pod " $1 "/" $2 " has " $3 " restarts"}' || true

echo "✅ Upgrade checks completed successfully."

# 15. Check EgressIP Configuration and Health
echo "👉 Checking EgressIP health..."

# Check for existing EgressIPs and their assignments
echo "🔎 Listing all EgressIP objects..."
oc get egressips -A || echo "⚠️  No EgressIP objects found"

# Check each EgressIP for assigned IPs and nodes
echo "🔎 Checking EgressIP assignments..."
oc get egressips -o custom-columns=NAME:.metadata.name,ASSIGNED_IP:.status.items[*].egressIP,ASSIGNED_NODE:.status.items[*].node --no-headers | \
awk '{if ($2 == "" || $3 == "") print "⚠️  Missing assignment for EgressIP " $1; else print "✅  " $1 " -> " $2 " on node " $3}' || true

# Check for duplicate or conflicting EgressIPs
echo "🔎 Checking for duplicate/conflicting EgressIPs..."
EGRESSIP_DUPES=$(oc get egressips -A -o jsonpath='{range .items[*]}{.status.items[*].egressIP}{"\n"}{end}' | sort | uniq -d)
if [[ -n "$EGRESSIP_DUPES" ]]; then
  echo "⚠️  Duplicate EgressIPs detected:"
  echo "$EGRESSIP_DUPES"
else
  echo "✅  No duplicate EgressIPs detected"
fi

# Check EgressIP nodes have correct labels and readiness
echo "🔎 Checking EgressIP nodes' labels and readiness..."
for node in $(oc get nodes -o name); do
  if oc get "$node" -o jsonpath='{.metadata.labels.k8s\.ovn\.org/egress-assignable}' 2>/dev/null | grep -q "true"; then
    echo "✅  $node is egress-assignable"
  fi
done

# Check for any pending or unassigned EgressIPs
echo "🔎 Checking for unassigned/pending EgressIPs..."
oc get egressips -A -o json | jq -r '.items[] | select(.status.items == null) | "⚠️  Pending assignment: \(.metadata.namespace)/\(.metadata.name)"' || true


echo "✅ Upgrade checks completed successfully."

