# Prometheus Metrics

Prometheus deployments for Outreach K8s clusters

CI/CD status with concourse: https://concourse.outreach.cloud/teams/devs/pipelines/prometheus

## Alertmanager Config

Currently, our Alertmanager receivers and routes are stored in the `deploy/prometheus/alertmanager-alerting` secret in Vault. To add configuration to this, the following steps are recommended:

1. Login to Vault and navigate to the designated path.
2. Copy the `alertmanager.yml` value.
3. Use ruby locally to parse the YAML string. `require 'yaml'; config = YAML.parse(copied_string)`
4. Add your config by manipulating the config hash.
5. Copy the result of `config.to_yaml` into the value.

## Update Pipeline

```Bash
outreach concourse update -p prometheus ci_cd/concourse/pipeline.jsonnet
```