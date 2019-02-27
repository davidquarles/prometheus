#!/usr/bin/env bash

CONTEXT="ops.us-west-2"

kubecfg validate manifests/*.jsonnet \
--jurl http://k8s-clusters.outreach.cloud/ \
--jurl https://raw.githubusercontent.com/getoutreach/jsonnet-libs/master \
-V cluster=${CONTEXT}
