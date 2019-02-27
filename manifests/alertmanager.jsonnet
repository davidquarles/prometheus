local ok = import 'kubernetes/outreach.libsonnet';
local cluster = ok.cluster;

local all(name, namespace) = {

  serviceaccount: ok.ServiceAccount(name, namespace),

  clusterrolebinding: ok.ClusterRoleBinding(name) {
    subjects_: [$.serviceaccount],
    roleRef_: ok.ClusterRole('cluster-admin'),
  },

  pvc: ok.PersistentVolumeClaim(name, namespace, app=name) {
    storage: '2Gi',
  },

  service: ok.Service(name, namespace, app=name) {
    target_pod:: $.deployment.spec.template,
    spec+: {
      ports: [
        { name: 'http', port: 80, targetPort: 'http' },
        { name: 'internal', port: 9093, targetPort: 'internal' },
      ],
    },
  },

  ingress: ok.ContourIngress(name, namespace, tlsSecret=name),

  deployment: ok.Deployment(name, namespace, app=name) {
    spec+: {
      template+: {
        spec+: {
          containers: [
            ok.Container('alertmanager') {
              local container = self,
              args: [
                '--config.file=/etc/alertmanager/alertmanager.yml',
                '--storage.path=/data',
                '--web.external-url=https://alertmanager.%s.%s.outreach.cloud' % [ok.cluster.environment, ok.cluster.region],
              ],
              image: 'prom/alertmanager:v0.14.0',
              ports_+: { internal: { containerPort: 9093 } },
              readinessProbe: {
                httpGet: {
                  path: '/#/status',
                  port: container.ports_.internal.containerPort,
                },
                initialDelaySeconds: 30,
                timeoutSeconds: 30,
              },
              resources: {
                limits: { memory: '100Mi' },
                requests: { cpu: '5m' },
              },
              volumeMounts_+: {
                config: { mountPath: '/etc/alertmanager' },
                data: { mountPath: '/data' },
              },
            },
            ok.Container('proxy') {
              args: [
                '-upstream=http://localhost:9093/',
                '-provider=okta',
                '-cookie-name=_alertmanager_proxy',
                '-cookie-secure=true',
                '-cookie-expire=168h0m',
                '-cookie-refresh=8h',
                '-cookie-domain=alertmanager.%s.%s.outreach.cloud' % [ok.cluster.environment, ok.cluster.region],
                '-http-address=0.0.0.0:80',
                '-okta-domain=outreach.okta.com',
                '-redirect-url=https://alertmanager.%s.%s.outreach.cloud/oauth2/callback' % [ok.cluster.environment, ok.cluster.region],
                '-email-domain=outreach.io',
              ],
              envFrom: [{ secretRef: { name: 'alertmanager-creds' } }],
              image: 'registry.outreach.cloud/oauth2_proxy:2.2.1-alpha.outreach-1.0.7',
              ports_+: {
                http: { containerPort: 80 },
              },
              resources: {
                limits: { memory: '100Mi' },
                requests: { cpu: '10m' },
              },
            },

            ok.Container('configmap-reload') {
              args: [
                '--volume-dir=/etc/alertmanager',
                '--webhook-url=http://localhost:9093/-/reload',
              ],
              image: 'jimmidyson/configmap-reload:v0.1',
              volumeMounts_+: { config: { mountPath: '/etc/alertmanager', readOnly: true } },
            },
          ],
          serviceAccountName: name,
          volumes_:: {
            config: ok.ConfigMapVolume(ok.ConfigMap(name, namespace)) {
              configMap+: {
                items: [
                  { key: 'alertmanager.yml', path: 'alertmanager.yml' },
                  { key: 'slack.text.tmpl', path: 'templates/slack.text.tmpl' },
                  { key: 'slack.title.tmpl', path: 'templates/slack.title.tmpl' },
                ],
              },
            },
            data: ok.PVCVolume($.pvc),
          },
        },
      },
    },
  },
};

ok.List() {
  items_: all('alertmanager', 'monitoring'),
}
