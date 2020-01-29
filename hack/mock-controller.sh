#!/usr/bin/env bash

k=kubectl

sync_period=10

operation_annotation="gardener.cloud/operation"
mock_type="mock"
mockos_type="mockos"

hack_dir=`echo ${BASH_SOURCE[0]%/*}`
manifest_dir=$hack_dir/manifests
charts_dir=${hack_dir%/*}/charts

secrets_path=`mktemp -d`
secret_path_gardener="$secrets_path/kubecfg.yaml"
secret_path_ca="$secrets_path/ca.crt"

env_pid=
secret_pid=
infra_pid=
controlplane_pid=
osc_pid=
network_pid=
worker_pid=

KIND_APISERVER_NODEPORT="30443"

cleanup () {
  echo "Exiting..."

  echo "Stopping env_controller (pid $env_pid)"
  [ -n "$env_pid" ] && kill $env_pid || true

  echo "Stopping secret_controller (pid $secret_pid)"
  [ -n "$secret_pid" ] && kill $secret_pid || true

  echo "Deleting secrets directory ($secrets_path)"
  [ -e "$secrets_path" ] && rm -rf "$secrets_path" || true

  echo "Stopping infra_controller (pid $infra_pid)"
  [ -n "$infra_pid" ] && kill $infra_pid || true

  echo "Stopping controlplane_controller (pid $controlplane_pid)"
  [ -n "$controlplane_pid" ] && kill $controlplane_pid || true

  echo "Stopping osc_controller (pid $osc_pid)"
  [ -n "$osc_pid" ] && kill $osc_pid || true

  echo "Stopping network_controller (pid $network_pid)"
  [ -n "$network_pid" ] && kill $network_pid || true

  echo "Stopping worker_controller (pid $worker_pid)"
  [ -n "$worker_pid" ] && kill $worker_pid || true
}

# checks if a given object has the given annotation with the given value
# $1 resource
# $2 object name
# $3 annotation name to check
# $4 value of annotation to check
has_annotation () {
  local value
  value=`$k get $1 "$2" -ojson | jq -r ".metadata.annotations[\"$3\"]"`
#  echo "desired=$4 value=$value"
  [ "$value" = "$4" ] && return 0 || return 1
}

# checks if a given object has the given extension type
# $1 resource
# $2 object name
# $3 type value to check
has_type () {
  local type
  type=`$k get $1 "$2" -ojson | jq -r ".spec.type"`
#  echo "desired=$3 type=$type"
  [ "$type" = "$3" ] && return 0 || return 1
}

get_generation () {
  local generation
  generation=`$k get $1 "$2" -ojson | jq -r ".metadata.generation"`
  echo "$generation"
}

K8S_ENV_KIND=kind
K8S_ENV_DOCKER_FOR_DESKTOP=docker-for-desktop
get_k8s_env () {
  if [ -n "$($k get no -oname | egrep 'kind|control-plane')" ] ; then
    echo "$K8S_ENV_KIND"
    return
  fi

  node_name=$($k get node -o jsonpath="{.items[0].metadata.name}")
  if [[ "$node_name" == "docker"* ]]; then
      echo "$K8S_ENV_DOCKER_FOR_DESKTOP"
      return
  fi

  if [[ "$node_name" == "$MINIKUBE" ]]; then
      echo "$MINIKUBE"
  fi

  return 1
}

k8s_env=`get_k8s_env`
if [ "$?" != 0 ] ; then
  >&2 echo "Your Kubernetes Environment is currently not yet supported by the mock provider."
  exit 1
fi
echo "Detected kubernetes environment: $k8s_env"

current_namespace="$($k config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)"
shoot_id=$current_namespace

if ! [[ "$shoot_id" =~ shoot--[a-zA-Z0-9-]+--[a-zA-Z0-9-]+ ]] ; then
  >&2 echo "Error: current kubeconfig not pointing to a shoot namespace: $current_namespace"
  exit 1
fi

HOST_IP_ROUTE=$(ip route get 1)
HOST_IP_ADDRESS=$(echo ${HOST_IP_ROUTE#*src} | awk '{print $1}')

if [ -z "$HOST_IP_ADDRESS" ] ; then
  >&2 echo "Error: could not determine the host's IP address"
  exit 1
fi

trap cleanup EXIT

# ====================================
# === env controller
# ====================================
# inject some environment specific stuff into the local seed cluster
env_controller () {
  local log
  log () {
    echo `date -Is` "[ENV]" "$@"
  }

  while true ; do
    log "starting sync"

    case "$k8s_env" in
      $K8S_ENV_KIND)
        log "reconciling $K8S_ENV_KIND seed"

        if $k get ns -l seed.gardener.cloud/provider=$mock_type -oname | grep $shoot_id > /dev/null ; then
          if $k get svc kube-apiserver > /dev/null 2> /dev/null ; then
            if [ "$($k get svc kube-apiserver -ojson | jq -r '.spec.ports[] | select(.name == "kube-apiserver").nodePort')" != "$KIND_APISERVER_NODEPORT" ] ; then
              log "patching kube-apiserver service to nodePort $KIND_APISERVER_NODEPORT"
              $k patch svc kube-apiserver --type=merge -p '{"spec": {"ports": [{"name": "kube-apiserver","nodePort": '$KIND_APISERVER_NODEPORT',"port": 443,"protocol": "TCP","targetPort": 443}]}}'
            fi

            if [ "$($k get svc kube-apiserver -ojson | jq -r '.status.loadBalancer.ingress[]?.ip')" != "$HOST_IP_ADDRESS" ] ; then
              log "patching kube-apiserver service status to ip $HOST_IP_ADDRESS"
              $hack_dir/patch-status.sh api/v1 services "$shoot_id" kube-apiserver '{"status":{"loadBalancer":{"ingress":[{"ip":"'$HOST_IP_ADDRESS'"}]}}}'
            fi
          fi
        fi
      ;;

      $K8S_ENV_DOCKER_FOR_DESKTOP)
        log "reconciling $K8S_ENV_K8S_ENV_DOCKER_FOR_DESKTOP seed"

        if $k get ns -l seed.gardener.cloud/provider=$mock_type -oname | grep $shoot_id > /dev/null ; then
          if $k get svc kube-apiserver > /dev/null 2> /dev/null ; then
            if [ "$($k get svc kube-apiserver -ojson | jq -r '.status.loadBalancer.ingress[]?.ip')" != "$HOST_IP_ADDRESS" ] ; then
              log "patching kube-apiserver service status to ip $HOST_IP_ADDRESS"
              $hack_dir/patch-status.sh api/v1 services "$shoot_id" kube-apiserver '{"status":{"loadBalancer":{"ingress":[{"ip":"'$HOST_IP_ADDRESS'"}]}}}'
            fi
          fi
        fi
      ;;
    esac

    sleep $sync_period
  done
}

echo "Starting env_controller"
env_controller &
env_pid=$!
echo "env_pid=$env_pid"


# ====================================
# === secret controller
# ====================================
# retrieves all relevant secrets in a loop to deal with changing kubeconfigs and ca certs
secret_controller () {
  local log
  log () {
    echo `date -Is` "[SECRET]" "$@"
  }

  while true ; do
    log "starting sync"

    log "Retrieving 'gardener' secret"
    $k get secret gardener -ojson | jq -r '.data["kubeconfig"]' | base64 -d > "$secret_path_gardener"

    log "Retrieving 'ca' secret"
    $k get secret ca -ojson | jq -r '.data["ca.crt"]' | base64 -d > "$secret_path_ca"

    sleep $sync_period
  done
}

echo "Starting secret_controller"
secret_controller &
secret_pid=$!
echo "secret_pid=$secret_pid"


# ====================================
# === infrastructure controller
# ====================================
infra_controller () {
  local log
  log () {
    echo `date -Is` "[INFRA]" "$@"
  }

  while true ; do
    log "starting sync"
    for infra in `$k get infra -ocustom-columns=:.metadata.name --no-headers` ; do
      log "checking if $infra should be reconciled"
      has_annotation infra $infra $operation_annotation reconcile || continue
      has_type infra $infra $mock_type || continue
      log "reconciling $infra"

      log "patching '$infra' status to 'Succeeded'"
      generation=`get_generation infra $infra`
      $hack_dir/patch-status.sh apis/extensions.gardener.cloud/v1alpha1 infrastructures "$shoot_id" $infra '{"status":{"observedGeneration": '$generation', "providerStatus":{}, "lastOperation":{"description":"test", "lastUpdateTime":"2019-01-01T00:00:00Z", "progress":100, "type":"Reconcile", "state":"Succeeded"}}}'

      log "removing reconcile annotation of '$infra'"
      $k annotate infra $infra gardener.cloud/operation- >/dev/null
    done

    sleep $sync_period
  done
}

echo "Starting infra_controller"
infra_controller &
infra_pid=$!
echo "infra_pid=$infra_pid"


# ====================================
# === controlplane controller
# ====================================
controlplane_controller () {
  local log
  log () {
    echo `date -Is` "[CONTROLPLANE]" "$@"
  }

  while true ; do
    log "starting sync"
    for cp in `$k get cp -ocustom-columns=:.metadata.name --no-headers` ; do
      log "checking if $cp should be reconciled"
      has_annotation cp $cp $operation_annotation reconcile || continue
      has_type cp $cp $mock_type || has_type cp $cp docker-for-desktop || continue
      log "reconciling $cp"

      log "patching '$cp' status to 'Succeeded'"
      generation=`get_generation cp $cp`
      $hack_dir/patch-status.sh apis/extensions.gardener.cloud/v1alpha1 controlplanes "$shoot_id" $cp '{"status":{"observedGeneration": '$generation', "providerStatus":{}, "lastOperation":{"description":"test", "lastUpdateTime":"2019-01-01T00:00:00Z", "progress":100, "type":"Reconcile", "state":"Succeeded"}}}'

      log "removing reconcile annotation of '$cp'"
      $k annotate cp $cp gardener.cloud/operation- >/dev/null
    done

    sleep $sync_period
  done
}

echo "Starting controlplane_controller"
controlplane_controller &
controlplane_pid=$!
echo "controlplane_pid=$controlplane_pid"


# ====================================
# === osc controller
# ====================================
osc_controller () {
  local log
  log () {
    echo `date -Is` "[OSC]" "$@"
  }

  while true ; do
    log "starting sync"
    for osc in `$k get osc -ocustom-columns=:.metadata.name --no-headers` ; do
      log "checking if $osc should be reconciled"
      has_annotation osc $osc $operation_annotation reconcile || continue
      has_type osc $osc $mockos_type || continue
      log "reconciling $osc"

      secretName="osc-result-$osc"

      if $k -n $shoot_id get secret $secretName >/dev/null 2>/dev/null ; then
        log "secret '$secretName' in namespace '$shoot_id' already exists"
      else
        log "creating secret '$secretName' in namespace '$shoot_id'"
        $k -n $shoot_id create secret generic $secretName --from-literal=cloud_config='# cloud config mock' >/dev/null
      fi

      log "patching '$osc' status to 'Succeeded'"
      generation=`get_generation osc $osc`
      $hack_dir/patch-status.sh apis/extensions.gardener.cloud/v1alpha1 operatingsystemconfigs "$shoot_id" $osc '{"status":{"observedGeneration": '$generation', "cloudConfig":{ "secretRef":{ "name": "'$secretName'", "namespace": "'$shoot_id'"}}, "units": [], "lastOperation":{"description":"test", "lastUpdateTime":"2019-01-01T00:00:00Z", "progress":100, "type":"Reconcile", "state":"Succeeded"}}}'

      log "removing reconcile annotation of '$osc'"
      $k annotate osc $osc gardener.cloud/operation- >/dev/null
    done

    sleep 5
  done
}

echo "Starting osc_controller"
osc_controller &
osc_pid=$!
echo "osc_pid=$osc_pid"


# ====================================
# === network controller
# ====================================
network_controller () {
  local log
  log () {
    echo `date -Is` "[NETWORK]" "$@"
  }

  while true ; do
    log "starting sync"
    for network in `$k get network -ocustom-columns=:.metadata.name --no-headers` ; do
      log "checking if $network should be reconciled"
      has_annotation network $network $operation_annotation reconcile || continue
      has_type network $network $mock_type || continue
      log "reconciling $network"

      $k --kubeconfig "$secret_path_gardener" apply -f "$manifest_dir/calico.yaml"

      $k --kubeconfig "$secret_path_gardener" -n kube-system patch svc vpn-shoot --patch '{"spec":{"type": "LoadBalancer", "ports":[{"name": "openvpn","nodePort": 30123,"port": 4314,"protocol": "TCP","targetPort": 1194}]}}' --type=merge
      KUBECONFIG="$secret_path_gardener" $hack_dir/patch-status.sh api/v1 services kube-system vpn-shoot '{"status":{"loadBalancer":{"ingress":[{"hostname":"mock-vpn-shoot.'$shoot_id'"}]}}}'

      log "patching '$network' status to 'Succeeded'"
      generation=`get_generation network $network`
      $hack_dir/patch-status.sh apis/extensions.gardener.cloud/v1alpha1 networks "$shoot_id" $network '{"status":{"observedGeneration": '$generation', "providerStatus":{}, "lastOperation":{"description":"test", "lastUpdateTime":"2019-01-01T00:00:00Z", "progress":100, "type":"Reconcile", "state":"Succeeded"}}}'

      log "removing reconcile annotation of '$network'"
      $k annotate network $network gardener.cloud/operation- >/dev/null
    done

    sleep $sync_period
  done
}

echo "Starting network_controller"
network_controller &
network_pid=$!
echo "network_pid=$network_pid"


# ====================================
# === worker controller
# ====================================
worker_controller () {
  local log
  log () {
    echo `date -Is` "[WORKER]" "$@"
  }

  while true ; do
    log "starting sync"
    for worker in `$k get worker -ocustom-columns=:.metadata.name --no-headers` ; do
      log "checking if $worker should be reconciled"
      has_type worker $worker $mock_type || continue

      local worker_json=`$k get worker $worker -ojson`
      local worker_deleted=no
      [ "$($k get worker $worker -oyaml | yaml2json | jq -r '.metadata.deletionTimestamp')" != null ] && worker_deleted=yes

      has_annotation worker $worker $operation_annotation reconcile || [ $worker_deleted = yes ] || continue

      log "reconciling $worker"

      $k --kubeconfig "$secret_path_gardener" apply -f "$manifest_dir/node-self-deleter.yaml"

      local bootstrap_token_name=`$k --kubeconfig "$secret_path_gardener" -n kube-system get secret --field-selector type=bootstrap.kubernetes.io/token -ocustom-columns=:.metadata.name --no-headers | head -1` || continue
      if [ -z "$bootstrap_token_name" ] ; then
        log "no bootstrap token found for shoot cluster"
        continue
      fi

      local worker_pool_name=`echo $worker_json | jq -r '.spec.pools[0].name'`

      local k8s_version=`$k get cluster $shoot_id -ojson | jq -r '.spec.shoot.spec.kubernetes.version'`

      local bootstrap_token_json=`$k --kubeconfig "$secret_path_gardener" -n kube-system get secret $bootstrap_token_name -ojson`
      local bootstrap_token_id=`echo $bootstrap_token_json | jq -r '.data["token-id"]' | base64 -d`
      local bootstrap_token_secret=`echo $bootstrap_token_json | jq -r '.data["token-secret"]' | base64 -d`
      local bootstrap_token_composed="$bootstrap_token_id.$bootstrap_token_secret"

      log "bootstrap_token_composed=$bootstrap_token_composed"

      if [ $worker_deleted = no ] ; then
        log "adding finalizer to worker $worker"
        $k patch worker $worker -p '{"metadata":{"finalizers":["extensions.gardener.cloud/worker"]}}' --type=merge

        helm template mock-shoot-worker --namespace $shoot_id --atomic $charts_dir/dind-node --set-file auth.caCert=$secret_path_ca --set auth.bootstrapToken=$bootstrap_token_composed --set worker.name=$worker_pool_name | $k apply -f -

        log "patching '$worker' status to 'Succeeded'"
        generation=`get_generation worker $worker`
        $hack_dir/patch-status.sh apis/extensions.gardener.cloud/v1alpha1 workers "$shoot_id" $worker '{"status":{"observedGeneration": '$generation', "providerStatus":{}, "lastOperation":{"description":"test", "lastUpdateTime":"2019-01-01T00:00:00Z", "progress":100, "type":"Reconcile", "state":"Succeeded"}}}'

        log "removing reconcile annotation of '$worker'"
        $k annotate worker $worker gardener.cloud/operation- >/dev/null
      else
        log "worker $worker deleted"

        $k scale deployment mock-shoot-worker --replicas 0

        until [ `$k get po -l app=dind-node 2&>/dev/null | wc -l` = 0 ] ; do
          log "waiting for dind-node Pods to be deleted"
          sleep 2
        done

        $k patch worker $worker -p '{"metadata":{"finalizers":null}}' --type=merge
        helm template mock-shoot-worker --namespace $shoot_id --atomic $charts_dir/dind-node --set-file auth.caCert=$secret_path_ca --set auth.bootstrapToken=$bootstrap_token_composed --set worker.name=$worker_pool_name | $k delete -f -
      fi

    done

    sleep $sync_period
  done
}

echo "Starting worker_controller"
worker_controller &
worker_pid=$!
echo "worker_pid=$worker_pid"


# ====================================
# === keep all controllers running
# ====================================
while true ; do
  sleep $sync_period
done
