#!/bin/bash

# Set this to "namespace" or "node"
AGGREGATE_BY="namespace"

if [ "$AGGREGATE_BY" = "namespace" ]; then
  echo "Namespace,CPU Requests (cores),CPU Limits (cores),Memory Requests (Mi),Memory Limits (Mi)"
  kubectl get pods --all-namespaces -o json | jq -r '
    .items[] |
    {
      ns: .metadata.namespace,
      containers: .spec.containers
    } |
    .containers // [] |
    map({
      ns: .ns,
      cpu_req: (.resources.requests.cpu // "0"),
      cpu_lim: (.resources.limits.cpu // "0"),
      mem_req: (.resources.requests.memory // "0"),
      mem_lim: (.resources.limits.memory // "0")
    })[] |
    [.ns, .cpu_req, .cpu_lim, .mem_req, .mem_lim] | @tsv
  ' | awk '
  function parse_cpu(val) {
    if (val ~ /m$/) return val + 0
    else return val * 1000
  }
  function parse_mem(val) {
    if (val ~ /Ki$/) { sub(/Ki/, "", val); return val / 1024 }
    if (val ~ /Mi$/) { sub(/Mi/, "", val); return val }
    if (val ~ /Gi$/) { sub(/Gi/, "", val); return val * 1024 }
    return 0
  }
  {
    ns=$1
    cpu_req=parse_cpu($2)
    cpu_lim=parse_cpu($3)
    mem_req=parse_mem($4)
    mem_lim=parse_mem($5)
    cpu_req_sum[ns]+=cpu_req
    cpu_lim_sum[ns]+=cpu_lim
    mem_req_sum[ns]+=mem_req
    mem_lim_sum[ns]+=mem_lim
  }
  END {
    for (ns in cpu_req_sum)
      printf "%s,%.2f,%.2f,%.2f,%.2f\n", ns, cpu_req_sum[ns]/1000, cpu_lim_sum[ns]/1000, mem_req_sum[ns], mem_lim_sum[ns]
  }'

elif [ "$AGGREGATE_BY" = "node" ]; then
  echo "Node,CPU Requests (cores),CPU Limits (cores),Memory Requests (Mi),Memory Limits (Mi)"
  kubectl get pods --all-namespaces -o json | jq -r '
    .items[] |
    select(.spec.nodeName != null) |
    {
      node: .spec.nodeName,
      containers: .spec.containers
    } |
    .containers // [] |
    map({
      node: .node,
      cpu_req: (.resources.requests.cpu // "0"),
      cpu_lim: (.resources.limits.cpu // "0"),
      mem_req: (.resources.requests.memory // "0"),
      mem_lim: (.resources.limits.memory // "0")
    })[] |
    [.node, .cpu_req, .cpu_lim, .mem_req, .mem_lim] | @tsv
  ' | awk '
  function parse_cpu(val) {
    if (val ~ /m$/) return val + 0
    else return val * 1000
  }
  function parse_mem(val) {
    if (val ~ /Ki$/) { sub(/Ki/, "", val); return val / 1024 }
    if (val ~ /Mi$/) { sub(/Mi/, "", val); return val }
    if (val ~ /Gi$/) { sub(/Gi/, "", val); return val * 1024 }
    return 0
  }
  {
    node=$1
    cpu_req=parse_cpu($2)
    cpu_lim=parse_cpu($3)
    mem_req=parse_mem($4)
    mem_lim=parse_mem($5)
    cpu_req_sum[node]+=cpu_req
    cpu_lim_sum[node]+=cpu_lim
    mem_req_sum[node]+=mem_req
    mem_lim_sum[node]+=mem_lim
  }
  END {
    for (node in cpu_req_sum)
      printf "%s,%.2f,%.2f,%.2f,%.2f\n", node, cpu_req_sum[node]/1000, cpu_lim_sum[node]/1000, mem_req_sum[node], mem_lim_sum[node]
  }'
else
  echo "❌ Set AGGREGATE_BY to 'namespace' or 'node'"
  exit 1
fi
