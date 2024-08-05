# assuming there are no pre-existing temp.file.oc.* files in the present working dir

oc get clusterversion

echo "\n[Cluster Nodes] =====>"
# get node instance-type, cpu, memory
oc get nodes -o json | jq -r '.items[] | [.metadata.name, .metadata.labels["node.kubernetes.io/instance-type"], .status.capacity["cpu"], .status.capacity["memory"]] | @tsv' > temp.file.oc.1

# get node roles
oc get nodes | awk '{ print $3 }' | tail +2 > temp.file.oc.2

# get node taints
for node in `oc get nodes | awk '{ print $1 }' | tail +2`; do oc describe node $node | grep -i taint | awk '{ print $2 }'; done > temp.file.oc.3

paste temp.file.oc.1 temp.file.oc.2 temp.file.oc.3 | sort -k 5

rm temp.file.oc.*

# get cluster network
echo "\n[Cluster Network] =====>"
oc get network/cluster -o yaml

# get resource quotas
echo "\n[Resource Quotas] =====>"
oc get resourcequotas -A -o json | jq -r '.items[] | [.metadata.namespace, .spec.hard.cpu] | @csv'