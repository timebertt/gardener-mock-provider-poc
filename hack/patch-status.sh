#!/usr/bin/env bash

# ====================================
# === patch status
# ====================================
# patch status of given resource with curl
# looks for kubeconfig in KUBECONFIG env var
# example:
#   patch_status "api/v1" "services" "shoot--dev--mock-shoot" "kube-apiserver"

log () {
  echo `date -Is` "[PATCH]" "$@"
}

if [ -z "$KUBECONFIG" ] ; then
  >&2 log "could not patch resource: KUBECONFIG env var not set"
  exit 1
fi

server=`kubectl config view --minify --output 'jsonpath={..server}'`
if [ -z "$server" ] ; then
  >&2 log "could not patch resource: server not set in KUBECONFIG"
  exit 1
fi

clientKey=`kubectl config view --minify --output 'jsonpath={..client-key-data}' --raw | base64 -d`
if [ -z "$clientKey" ] ; then
  >&2 log "could not patch resource: client-key-data not set in KUBECONFIG"
  exit 1
fi

clientCert=`kubectl config view --minify --output 'jsonpath={..client-certificate-data}' --raw | base64 -d`
if [ -z "$clientCert" ] ; then
  >&2 log "could not patch resource: client-key-data not set in KUBECONFIG"
  exit 1
fi

apiPath=$1
if [ -z "$apiPath" ] ; then
  >&2 log "could not patch resource: \$1 should be apiPath, for example: 'api/v1' or 'apis/apps/v1'"
  exit 1
fi

resource=$2
if [ -z "$resource" ] ; then
  >&2 log "could not patch resource: \$2 should be resource, for example: 'services' or 'infrastructures'"
  exit 1
fi

namespace=$3
if [ -z "$namespace" ] ; then
  >&2 log "could not patch resource: \$3 should be namespace, for example: 'shoot--dev--mock-shoot'"
  exit 1
fi

name=$4
if [ -z "$name" ] ; then
  >&2 log "could not patch resource: \$4 should be name, for example: 'kube-apiserver'"
  exit 1
fi

patchData=$5
if [ -z "$patchData" ] ; then
  >&2 log "could not patch resource: \$5 should be patchData, for example: "'{"status":{"loadBalancer":{"ingress":[{"hostname":"10.0.0.123"}]}}}'
  exit 1
fi

url="$server/$apiPath/namespaces/$namespace/$resource/$name/status"

log "patching $url with patch '$patchData'"

response_file=`mktemp`

response_code=$(curl -k -XPATCH --silent -o $response_file --key <(echo "$clientKey") --cert <(echo "$clientCert") \
  -H "Accept: application/json" -H "Content-Type: application/merge-patch+json" \
  -w "%{http_code}" \
  "$url" --data-raw "$patchData")

log "response code: $response_code"

if [ "$response_code" != "200" ] ; then
  log "response body: `cat $response_file`"
fi

rm $response_file
