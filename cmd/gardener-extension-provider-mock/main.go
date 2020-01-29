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
	"flag"
	"os"
	"path"
	"sigs.k8s.io/controller-runtime/pkg/client/config"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/manager/signals"
	"sigs.k8s.io/controller-runtime/pkg/webhook"
)

var log = logf.Log.WithName("provider-mock")

func main() {
	logf.SetLogger(zap.New(zap.UseDevMode(false)))
	entryLog := log.WithName("entrypoint")

	webhookPort := flag.Int("webhook-port", 443, "Port to use for the webhook server")
	flag.Parse()

	// Setup a Manager
	entryLog.Info("setting up manager")
	pwd, err := os.Getwd()
	if err != nil {
		entryLog.Error(err, "unable to got current working directory")
		os.Exit(1)
	}

	certDir := path.Join(pwd, "tls")

	mgr, err := manager.New(config.GetConfigOrDie(), manager.Options{CertDir: certDir, Port: *webhookPort})
	if err != nil {
		entryLog.Error(err, "unable to set up overall controller manager")
		os.Exit(1)
	}

	// Setup webhooks
	entryLog.Info("setting up webhook server")
	hookServer := mgr.GetWebhookServer()

	entryLog.Info("registering webhooks to the webhook server")
	hookServer.Register("/service", &webhook.Admission{Handler: &svcValidator{logger: log.WithValues("webhook", "/service")}})
	hookServer.Register("/statefulset", &webhook.Admission{Handler: &stsMutator{logger: log.WithValues("webhook", "/statefulset")}})

	entryLog.Info("starting manager")
	if err := mgr.Start(signals.SetupSignalHandler()); err != nil {
		entryLog.Error(err, "unable to run manager")
		os.Exit(1)
	}
}
