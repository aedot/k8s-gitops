#!/bin/bash

output_file="pod-resources.csv"
echo "Namespace,Pod,Container,CPU Request,CPU Limit,Memory Request,Memory Limit" > "$output_file"

kubectl get pods --all-namespaces -o json | jq -r '
  .items[] |
  {
    ns: .metadata.namespace,
    pod: .metadata.name,
    containers: .spec.containers
  } |
  .containers[] as $c |
  [
    .ns,
    .pod,
    $c.name,
    ($c.resources.requests.cpu // "0"),
    ($c.resources.limits.cpu // "0"),
    ($c.resources.requests.memory // "0"),
    ($c.resources.limits.memory // "0")
  ] | @csv
' >> "$output_file"

echo "✅ Cleaned pod resource info written to $output_file"
