/*
Copyright 2018 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/go-logr/logr"
	v1 "k8s.io/api/apps/v1"
	"net/http"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// svcValidator intercepts updates to the service status of the kube-apiserver svc in the shoot's control plane
type svcValidator struct {
	client  client.Client
	decoder *admission.Decoder
	logger  logr.Logger
}

// svcValidator admits a pod iff a specific annotation exists.
func (v *svcValidator) Handle(ctx context.Context, req admission.Request) admission.Response {
	v.logger.Info("Received request")
	if req.Resource.Resource != "services" || req.Resource.Group != "" || req.SubResource != "status" {
		return admission.Allowed("")
	}

	service := &corev1.Service{}

	err := v.decoder.Decode(req, service)
	if err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}

	v.logger.Info("received update for service status", "namespace", service.Namespace, "name", service.Name)

	if ingress := service.Status.LoadBalancer.Ingress; len(ingress) > 0 {
		for _, i := range ingress {
			if i.Hostname == "localhost" {
				return admission.Errored(http.StatusBadRequest, fmt.Errorf("not allowed to set localhost as LoadBalancer ingress hostname"))
			}
		}
	}

	return admission.Allowed("")
}

func (v *svcValidator) InjectClient(c client.Client) error {
	v.client = c
	return nil
}

func (v *svcValidator) InjectDecoder(d *admission.Decoder) error {
	v.decoder = d
	return nil
}

// stsMutator intercepts updates to etcd statefulsets and mutates it, so that it can get ready without the etcdbr sidecar
type stsMutator struct {
	client  client.Client
	decoder *admission.Decoder
	logger  logr.Logger
}

// stsMutator admits a pod iff a specific annotation exists.
func (v *stsMutator) Handle(ctx context.Context, req admission.Request) admission.Response {
	v.logger.Info("Received request")
	if req.Resource.Resource != "statefulsets" || req.Resource.Group != "apps" || req.SubResource != "" {
		return admission.Allowed("")
	}

	sts := &v1.StatefulSet{}

	err := v.decoder.Decode(req, sts)
	if err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}

	v.logger.Info("received update for statefulset", "namespace", sts.Namespace, "name", sts.Name)

	if sts.Name == "etcd-main" || sts.Name == "etcd-events" {
		for i, c := range sts.Spec.Template.Spec.Containers {
			if c.Name != "etcd" {
				continue
			}

			c.Command = []string{
				"etcd", "--config-file", "/bootstrap/etcd.conf.yml",
			}

			c.ReadinessProbe.HTTPGet = nil
			c.ReadinessProbe.Exec = &corev1.ExecAction{Command: []string{
				"/bin/sh",
				"-ec",
				"ETCDCTL_API=3",
				"etcdctl",
				"--cert=/var/etcd/ssl/client/tls.crt",
				"--key=/var/etcd/ssl/client/tls.key",
				"--cacert=/var/etcd/ssl/ca/ca.crt",
				fmt.Sprintf("--endpoints=https://%s-0:%d", sts.Name, 2379),
				"endpoint",
				"health",
			}}

			c.Ports = append(c.Ports, corev1.ContainerPort{
				Name:          "metrics",
				ContainerPort: 8080,
				Protocol:      "TCP",
			})

			sts.Spec.Template.Spec.Containers[i] = c
		}

		marshaledSts, err := json.Marshal(sts)
		if err != nil {
			return admission.Errored(http.StatusInternalServerError, err)
		}

		return admission.PatchResponseFromRaw(req.Object.Raw, marshaledSts)
	}

	return admission.Allowed("")
}

func (v *stsMutator) InjectClient(c client.Client) error {
	v.client = c
	return nil
}

func (v *stsMutator) InjectDecoder(d *admission.Decoder) error {
	v.decoder = d
	return nil
}
