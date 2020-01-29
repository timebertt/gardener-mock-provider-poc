# gardener-mock-provider-poc

This repo contains files and resources from a POC for a Gardener Mock Provider Extension.
It was presented in the Gardener Community on Jan 24th (see [Resources](#resources)).

# Status of the Mock Provider
This POC implements the Mock Provider in a simple bash script (plus some manifests and charts) that loops over all extensions and patches them to Succeeded.  
These resources are not supposed to be seen as "ready for usage".
This Proof of concept was only done to see if the concept of a Mock Provider can actually work
and to discover technical restrictions in the process.
Nevertheless, you are of course welcome to try it out (see [Walkthrough](#walkthrough)) and provide feedback if you want!

As the POC worked out (though, with some limitations), there will be a "real" implementation
for the Mock Provider but it is not done yet.  
[gardener/gardener-extension-provider-mock](https://github.com/gardener/gardener-extension-provider-mock) will be the home for this provider implementation. This issue will be used to track the implementation: [gardener/gardener-extension-provider-mock#1](https://github.com/gardener/gardener-extension-provider-mock/issues/1)

# Basic Concept

## What is the Mock Provider?
The Mock Provider is an alternative provider to the other IaaS providers, which implements Gardener Extension Points.
But in contrast to "normal" infrastructure providers, it does not create any real infrastructure.

## Why is the Mock Provider needed?
We want to able to:
- develop Gardener faster and without any Infrastructure
- run Gardener tests faster and more cost-efficiently
- so basically be independent from Extensions/IaaS for these scenarios

## How does the Mock Provider work?
Gardener Extensibility (see [GEP 1](https://github.com/gardener/gardener/blob/master/docs/proposals/01-extensibility.md))
already provides extension points for different provider implementations. 
Gardener itself only creates/annotates the Extension Resources and waits for the Extension Resources to be ready.  
The Mock local provider simply sets Extension Resources to ready without doing anything.  
The Mock Provider can be installed via a ControllerRegistration object just like the other extensions and
can run on a real Seed or a local cluster (for example docker-for-desktop/kind).

# Walkthrough

Follow these steps, if you want to test the Mock Provider in your local setup and create a Mock Shoot on your development machine.

1. Configure your local Gardener Dev Setup  
see: [Gardener Local Dev Setup](https://github.com/gardener/gardener/blob/master/docs/development/local_setup.md) (only steps until `make dev-setup` (incl.) are needed)

1. If you don't have it already, create the `dev` Project.
    ```shell script
    kubectl apply -f example/05-project-dev.yaml
    ```

1. Create the Mock `CloudProfile`:
    ```shell script
    kubectl apply -f example/20-cloudprofile-mock.yaml
    ```

1. Create a Kubernetes cluster which you want to use as your local Seed.
If you are using a docker-for-desktop cluster in your local setup, you can use that one and go to the next step.  
Alternatively you can also create a cluster with [kind](https://kind.sigs.k8s.io/).
In that case, you need to add a port mapping from 443 on your host machine to 30443 on the kind node,
which will be used later to expose the Mock Shoot's `kube-apiserver` Service via NodePort.  
You can do that by using the example kind config:
    ```shell script
    kind create cluster --name kind-seed --config example/10-kind-seed.yaml --kubeconfig $HOME/.kube/configs/kind-seed.yaml
    ```

1. Now, get the kubeconfig to your local cluster and put it in `example/30-secret-seed.yaml`.  
For kind, you can use this command:
    ```shell script
    kind get kubeconfig --name kind-seed
    ```

1. Register your docker-for-desktop/kind cluster as a Seed in your local setup:  
    ```shell script
    kubectl apply -f example/30-secret-seed.yaml
    kubectl apply -f example/35-seed.yaml
    ```

1. Create the `ControllerRegistration` for the Mock Provider:
    ```shell script
    kubectl apply -f example/40-controller-registration-mock.yaml
    ```

1. Create a faked infrastructure `Secret` and a corresponding `SecretBinding` that will be referenced by the Mock Shoot:
    ```shell script
    kubectl apply -f example/50-mock-secret.yaml
    ```

1. Now, you can go ahead and create the Mock Shoot:
    ```shell script
    kubectl apply -f example/55-mock-shoot.yaml
    ```

1. Now open a new terminal window and point your KUBECONFIG to the Mock Shoot's namespace in the Seed.  
    ```shell script
    export KUBECONFIG=$HOME/.kube/configs/kind-seed.yaml
    kubens shoot--dev--mock-shoot
    ```
    In this terminal window start the Mock Provider controller (bash script) and keep it running:
    ```shell script
    ./hack/mock-controller.sh
    ```

1. Now you can watch your Mock Shoot being created on your local cluster.
After a while (about 6m) your Shoot should be reconciled completely and the Control Plane should look similar to this:
    ```shell script
    kubectl get po,infra,cp,osc,worker,network
    NAME                                             READY   STATUS    RESTARTS   AGE
    pod/etcd-events-0                                1/1     Running   0          22m
    pod/etcd-main-0                                  1/1     Running   0          22m
    pod/gardener-resource-manager-5fd66ccffd-x9nbs   1/1     Running   0          20m
    pod/kube-apiserver-79d5988bf9-pjxsx              3/3     Running   0          4m38s
    pod/kube-controller-manager-68dcf746fd-lfssd     1/1     Running   0          20m
    pod/kube-scheduler-b8f7d447d-r2csr               1/1     Running   0          20m
    pod/mock-shoot-worker-66fb6b9767-4gn7t           2/2     Running   0          6m13s
    
    NAME                                                  TYPE   REGION       STATUS      AGE
    infrastructure.extensions.gardener.cloud/mock-shoot   mock   mock-west1   Succeeded   22m
    
    NAME                                                         TYPE   PURPOSE    STATUS      AGE
    controlplane.extensions.gardener.cloud/mock-shoot            mock              Succeeded   21m
    controlplane.extensions.gardener.cloud/mock-shoot-exposure   mock   exposure   Succeeded   20m
    
    NAME                                                                                       TYPE     STATUS      PURPOSE     AGE
    operatingsystemconfig.extensions.gardener.cloud/cloud-config-cpu-worker-16ffc-downloader   mockos   Succeeded   provision   20m
    operatingsystemconfig.extensions.gardener.cloud/cloud-config-cpu-worker-16ffc-original     mockos   Succeeded   reconcile   20m
    
    NAME                                          TYPE   REGION       STATUS      AGE
    worker.extensions.gardener.cloud/mock-shoot   mock   mock-west1   Succeeded   20m
    
    NAME                                           TYPE   POD CIDR        SERVICE CIDR    STATUS      AGE
    network.extensions.gardener.cloud/mock-shoot   mock   100.96.0.0/11   100.64.0.0/13   Succeeded   20m
    ```

1. In the `garden-dev` namespace of your garden cluster there will be a secret containing the kubeconfig to your Mock Shoot.
Extract the kubeconfig from the `mock-shoot.kubeconfig` secret and use it to talk to your Shoot Cluster:
    ```shell script
    kubectl -n garden-dev get secret mock-shoot.kubeconfig -ojson | jq -r '.data.kubeconfig' | base64 -d
    ```
    The Shoot Cluster should look similar to this:
    ```shell script
    kubectl get no,po,svc --all-namespaces
    NAME                                      STATUS   ROLES    AGE   VERSION
    node/mock-shoot-worker-66fb6b9767-4gn7t   Ready    <none>   22m   v1.16.3
    
    NAMESPACE     NAME                                           READY   STATUS    RESTARTS   AGE
    kube-system   pod/calico-kube-controllers-74c9747c46-g7fnk   1/1     Running   0          37m
    kube-system   pod/calico-node-kchqv                          1/1     Running   0          22m
    kube-system   pod/coredns-f8b6b6d6d-lsqnd                    1/1     Running   0          37m
    kube-system   pod/coredns-f8b6b6d6d-mhgzv                    1/1     Running   0          36m
    kube-system   pod/kube-proxy-h5cdq                           1/1     Running   0          22m
    kube-system   pod/metrics-server-6786658f85-m58wc            1/1     Running   0          37m
    kube-system   pod/node-problem-detector-b5xp6                1/1     Running   0          22m
    kube-system   pod/vpn-shoot-845499bf7f-5cdq2                 1/1     Running   0          37m
    
    NAMESPACE     NAME                     TYPE           CLUSTER-IP       EXTERNAL-IP                             PORT(S)                  AGE
    default       service/kubernetes       ClusterIP      100.64.0.1       <none>                                  443/TCP                  38m
    kube-system   service/kube-dns         ClusterIP      100.64.0.10      <none>                                  53/UDP,53/TCP,9153/TCP   37m
    kube-system   service/kube-proxy       ClusterIP      None             <none>                                  10249/TCP                37m
    kube-system   service/metrics-server   ClusterIP      100.71.108.60    <none>                                  443/TCP                  37m
    kube-system   service/vpn-shoot        LoadBalancer   100.66.180.224   mock-vpn-shoot.shoot--dev--mock-shoot   4314:30123/TCP           37m
    ```

1. Now you basically have a fully functional Kubernetes Cluster running on your development machine.
You can test it by creating a nginx deployment and service and do a port-forward to the service:
    ```shell script
    kubectl run --image nginx nginx --expose --port 80
    kubectl port-forward svc/nginx 8080:80
    ```
    You should be able to reach the nginx welcome page via http://localhost:8080.

### Cleanup

Follow these steps to cleanup the resources created by the previous steps.

1. Delete the Mock Shoot itself. Make sure, the mock-controller is still running for the Shoot deletion to work.
    ```shell script
    kubectl -n garden-dev annotate shoots.core.gardener.cloud mock-shoot confirmation.garden.sapcloud.io/deletion=true
    kubectl -n garden-dev delete shoots.core.gardener.cloud mock-shoot --wait=false
    ```

1. Delete the Mock Provider `ControllerRegistration`:
    ```shell script
    kubectl delete ctrlreg provider-mock
    ```

1. Unregister your local `Seed`:
    ```shell script
    kubectl delete seed local-seed
    ```

1. Optionally delete your kind cluster:
    ```shell script
    kind delete cluster --name kind-seed
    ```


# Resources

Presentation in the Gardener Community Meeting on Jan 24th 2020:
- Slides: https://docs.google.com/presentation/d/1rf8Fd_UN8Gx8DldAzlACgmp1CCqSfdhVtKJ4BNdh-5I
- Recording: https://youtu.be/ChT7mdLEwKQ?t=30s
