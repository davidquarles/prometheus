local kubecfg = import 'kubecfg.libsonnet';
local ok = import 'kubernetes/outreach.libsonnet';
local t = import './trickster.libsonnet';

local all = {
  local name = 'trickster',
  local namespace = 'monitoring',
  local trickster = t.cache(name, namespace, 'thanos-query'),

  configmap: trickster.configmap,
  svc: ok.Service(name, namespace=namespace) { target_pod:: $.deployment.spec.template },
  deployment: ok.Deployment(name, namespace) {
    spec+: {
      template+: {
        metadata+: {
          annotations+: {
            trickster_ini: std.md5(trickster.config),
          },
        },
        spec+: {
          containers: [
            ok.Container(name) {
              image: trickster.image,
              ports_+:: { http: { containerPort: 9090 } },
              resources: {
                limits: { memory: '4Gi' },
                requests: { cpu: '500m' },
              },
              volumeMounts_+:: {
                config: { mountPath: '/etc/trickster' },
              },
            },
          ],
          volumes_+:: {
            config: ok.ConfigMapVolume(trickster.configmap),
          },
        },
      },
    },
  },
};

ok.List() { items_+: all }
