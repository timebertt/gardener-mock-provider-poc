# Copyright (c) 2019 SAP SE or an SAP affiliate company. All rights reserved. This file is licensed under the Apache Software License, v. 2 except as noted otherwise in the LICENSE file
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

REGISTRY                    := timebertsap
IMAGE_NAME                  := $(REGISTRY)/gardener-extension-provider-mock
VERSION						:= 0.1.0
LD_FLAGS                    := "-w"

### Build commands

.PHONY: all
all: docker-image

### Docker commands

.PHONY: docker-image
docker-image:
	@docker build -t $(IMAGE_NAME):$(VERSION) -t $(IMAGE_NAME):latest -f Dockerfile -m 6g --target gardener-extension-provider-mock .

.PHONY: docker-push
docker-push: docker-image
	@docker push $(IMAGE_NAME):$(VERSION)
	@docker push $(IMAGE_NAME):latest

### Debug / Development commands

.PHONY: revendor
revendor:
	@GO111MODULE=on go mod vendor
	@GO111MODULE=on go mod tidy

.PHONY: start-provider-mock
start-provider-mock:
	GO111MODULE=on go run \
		-mod=vendor \
		-ldflags $(LD_FLAGS) \
		./cmd/gardener-extension-provider-mock
