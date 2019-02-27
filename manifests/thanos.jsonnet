local kubecfg = import 'lib/kubecfg.libsonnet';
local ok = import 'kubernetes/outreach.libsonnet';
local t = import './trickster.libsonnet';

local all(namespace='monitoring') = {
  local bucket = 'outreach-thanos-%s' % ok.cluster.name,

  thanos(subcommand, name=null):: {
    local this = self,

    // gross but allows us to use this template for prometheus too
    name:: if name == null then 'thanos-%s' % subcommand else name,

    pdb: ok.PodDisruptionBudget(this.name, namespace) {
      spec+: {
        maxUnavailable: 1,
        selector: { matchLabels: this.statefulset.metadata.labels },
      },
    },

    serviceaccount: ok.ServiceAccount(this.name, namespace),

    statefulset: ok.StatefulSet(this.name, namespace) {
      metadata+: { labels+: { 'thanos-peer': 'true' } },
      spec+: {
        podManagementPolicy: 'Parallel',
        replicas: 2,
        template+: {
          metadata+: {
            annotations+: {
              'prometheus.io/port': '10902',
              'prometheus.io/scrape': 'true',
            },
          },
          spec+: {
            affinity: {
              nodeAffinity: {
                preferredDuringSchedulingIgnoredDuringExecution: [{
                  preference: {
                    local nodepools = [
                      'monitoring',
                      'monitoring-large',
                      'monitoring-xlarge',
                      'monitoring-2xlarge',
                      'monitoring-4xlarge',
                      'monitoring-8xlarge',
                      'monitoring-16xlarge',
                    ],
                    matchExpressions: [{
                      key: 'outreach.io/nodepool',
                      operator: 'In',
                      values: nodepools,
                    }],
                  },
                  weight: 100,
                }],
              },
              podAntiAffinity: {
                local topologyKeys = [
                  'kubernetes.io/hostname',
                  'failure-domain.beta.kubernetes.io/zone',
                ],
                requiredDuringSchedulingIgnoredDuringExecution: [
                  { labelSelector: { matchLabels: { name: this.name } }, topologyKey: k }
                  for k in topologyKeys
                ],
              },
            },
            containers_+:: {
              default: self.thanos_,  // allows no-clobber default override

              thanos_:: ok.Container('thanos-%s' % subcommand) {
                args_+:: { 'log.level': 'debug' },
                command: ['/bin/thanos', subcommand],
                env_:: {
                  GOOGLE_APPLICATION_CREDENTIALS: '/etc/google/creds.json',
                },
                image: 'improbable/thanos:v0.3.1',
                // as of today only thanos-query has /-/healthy
                // so we use /metrics elsewhere
                // we also probe prometheus's /-/healthy in thanos-sidecar
                livenessProbe: {
                  httpGet: {
                    path: '/metrics',
                    port: 'thanos-http',
                    scheme: 'HTTP',
                  },
                  initialDelaySeconds: 30,
                  timeoutSeconds: 30,
                },
                readinessProbe: self.livenessProbe {
                  initialDelaySeconds: 5,
                },
                ports_+:: {
                  'thanos-cluster': { containerPort: 10900 },
                  'thanos-grpc': { containerPort: 10901 },
                  'thanos-http': { containerPort: 10902 },
                },
                volumeMounts_+:: {
                  config: { mountPath: '/etc/prometheus' },
                  creds: { mountPath: '/etc/google', readOnly: true },
                  data: { mountPath: '/opt/thanos' },
                  'objstore-config': { mountPath: '/etc/thanos' },
                },
              },
            },
            initContainers_:: {
              chmod: ok.Container('chmod') {
                command: ['chmod', '-R', '0777', '/data'],
                image: 'busybox',
                volumeMounts_:: { data: { mountPath: '/data' } },
              },
            },
            serviceAccount: this.serviceaccount.metadata.name,
            tolerations: [{
              key: 'dedicated',
              operator: 'Equal',
              value: 'monitoring',
              effect: 'NoSchedule',
            }],
            volumes_:: {
              config: ok.ConfigMapVolume($.prometheus.configmap),
              creds: ok.SecretVolume(ok.Secret('google-creds', namespace)),
              'objstore-config': ok.ConfigMapVolume($['thanos-store'].configmap),
            },
          },
        },
        volumeClaimTemplates: [{
          metadata+: { name: 'data' },
          spec+: {
            accessModes: ['ReadWriteOnce'],
            storageClassName: 'io-max',
            resources: { requests: { storage: '100Gi' } },
          },
        }],
      },
    },

    vpa: ok.VerticalPodAutoscaler(this.name, namespace) {
      target_pod:: this.statefulset.spec.template,
      spec+: {
        resourcePolicy: {},
        updatePolicy+: {
          updateMode: 'Initial',
        },
      },
    },
  },

  prometheus: $.thanos('sidecar', name='prometheus') {
    local this = self,
    local name = 'prometheus',
    local trickster = t.cache('%s-trickster' % name, namespace, 'localhost', 9089),

    clusterrole+: ok.ClusterRole(this.name) {
      rules: [{
        apiGroups: [''],
        resources: ['endpoints', 'nodes', 'nodes/proxy', 'pods', 'services'],
        verbs: ['get', 'list', 'watch'],
      },{
        apiGroups: ['extensions'],
        resources: ['ingresses'],
        verbs: ['get', 'list', 'watch'],
      },{
        nonResourceURLs: ['/metrics'],
        verbs: ['get'],
      }],
    },

    clusterrolebinding: ok.ClusterRoleBinding(this.name) {
      roleRef_: this.clusterrole,
      subjects_: [this.serviceaccount],
    },

    configmap: ok.ConfigMap(name, namespace) {
      data: {
        'alerting.rules.yml': ok.manifestYaml(import './alerts.libsonnet'),
        'prometheus.yml.tmpl': importstr '../snippets/prometheus.yml.tmpl',
        'recording.rules.yml': importstr '../snippets/rules.yml',
      },
    },
    'trickster-configmap': trickster.configmap,
    ingress: ok.ContourIngress(name, namespace, serviceName='thanos-query', servicePort='http-proxy', tlsSecret=name) {
      metadata+: {
        annotations+: {
          'contour.heptio.com/request-timeout': '3m',
        },
      },
    },
    statefulset+: {
      spec+: {
        template+: {
          metadata+: {
            annotations+: {
              trickster_ini: std.md5(trickster.config),
            },
          },
          spec+: {
            containers_+: {
              default: ok.Container(name) {
                args: [
                  '--config.file=%s/prometheus.yml' % self.volumeMounts_['config-shared'].mountPath,
                  '--log.format=json',
                  '--query.max-concurrency=100',
                  '--storage.tsdb.max-block-duration=2h',
                  '--storage.tsdb.min-block-duration=2h',
                  '--storage.tsdb.path=%s' % self.volumeMounts_.data.mountPath,
                  '--storage.tsdb.retention=3h',
                  '--web.enable-lifecycle',
                  '--web.listen-address=0.0.0.0:9089',
                ],
                image: 'prom/prometheus:v2.6.0',
                livenessProbe: {
                  httpGet: {
                    path: '/-/healthy',
                    port: 9089,
                    scheme: 'HTTP',
                  },
                  initialDelaySeconds: 30,
                  timeoutSeconds: 30,
                },
                readinessProbe: {
                  httpGet: {
                    path: '/-/ready',
                    port: 9089,
                    scheme: 'HTTP',
                  },
                  initialDelaySeconds: 30,
                  timeoutSeconds: 30,
                },

                volumeMounts_:: {
                  'config-shared': { mountPath: '/etc/prometheus-shared' },
                  data: { mountPath: '/opt/prometheus' },
                },
              },
              'trickster-sidecar': ok.Container('trickster-sidecar') {
                image: trickster.image,
                ports_+:: { 'prom-http': { containerPort: 9090 } },
                volumeMounts_+:: {
                  'trickster-config': { mountPath: '/etc/trickster' },
                },
              },
              'thanos-sidecar': self.thanos_ {
                args+: [
                  '--objstore.config-file=/etc/thanos/objstore-config.yaml',
                  '--prometheus.url=http://localhost:9089',
                  '--reloader.config-envsubst-file=%s/prometheus.yml' % self.volumeMounts_['config-shared'].mountPath,
                  '--reloader.config-file=%s/prometheus.yml.tmpl' % self.volumeMounts_['config'].mountPath,
                  '--tsdb.path=%s' % self.volumeMounts_.data.mountPath,
                ],
                readinessProbe: {
                  exec: {
                    command: [
                      'wget', '-qO', '-',
                      'localhost:9089/-/ready',
                      'localhost:10902/metrics',
                    ],
                  },
                  initialDelaySeconds: 5,
                  timeoutSeconds: 30,
                },
                volumeMounts_+:: {
                  'config-shared': { mountPath: '/etc/prometheus-shared' },
                },
              },
            },
            terminationGracePeriodSeconds: 300,
            volumes_+:: {
              'config-shared': ok.EmptyDirVolume(),
              'trickster-config': ok.ConfigMapVolume(trickster.configmap),
            },
          },
        },
      },
    },
    service: ok.Service(name, namespace) {
      target_pod:: $[name].statefulset.spec.template,
      spec+: {
        ports: [
          { name: 'http-prometheus', port: 9090, targetPort: 'prom-http' },
          { name: 'http-sidecar-metrics', port: 10902, targetPort: 'thanos-http' },
        ],
      },
    },
  },

  'thanos-peers': {
    service: ok.Service('thanos-peers', namespace, app='thanos') {
      local port = self.target_pod.spec.containers_['thanos-sidecar'].ports_['thanos-cluster'].containerPort,
      target_pod:: $.prometheus.statefulset.spec.template,
      spec+: {
        clusterIP: 'None',
        ports: [{ name: 'cluster', port: port }],
        selector: { 'thanos-peer': 'true' },
      },
    },
  },

  'thanos-compact': $.thanos('compact') {
    statefulset+: {
      metadata+: { labels+: { 'thanos-peer': 'false' }}, // gossip opt-out
      spec+: {
        local extra_args = [
          '--data-dir=%s' % self.template.spec.containers_.default.volumeMounts_.data.mountPath,
          '--objstore.config-file=/etc/thanos/objstore-config.yaml',
          '--retention.resolution-raw=4w',
          '--retention.resolution-5m=13w',
          '--wait',
        ],
        replicas: 1,
        template+: { spec+: { containers_+:: { default+: { args+: extra_args }}}},
      },
    },
  },

  'thanos-query': $.thanos('query') {
    service: ok.Service(self.name, namespace) {
      target_pod:: $[self.metadata.name].statefulset.spec.template,
      spec+: {
        ports: [
          { name: 'http-proxy', port: 9091, targetPort: 'proxy' },
          { name: 'http-query', port: 9090, targetPort: 'thanos-http' },
        ],
      },
    },
    statefulset+: {
      spec+: {
        local extra_args = [
          '--cluster.peers=thanos-peers.%s.svc.cluster.local:10900' % namespace,
          '--query.auto-downsampling',
          '--query.replica-label=replica',
          '--query.max-concurrent=100',
          '--query.timeout=2m',
        ],
        template+: {
          spec+: {
            containers_+:: {
              default+: {
                args+: extra_args,
                // as of today only thanos-query has /-/healthy
                livenessProbe+: { httpGet+: { path: '/-/healthy' }},
                readinessProbe+: { httpGet+: { path: '/-/healthy' }},
              },
              proxy: ok.Container('proxy') {
                args: [
                  '-cookie-domain=%s' % $.prometheus.ingress.host,
                  '-cookie-expire=168h0m',
                  '-cookie-name=_prometheus_proxy',
                  '-cookie-refresh=8h',
                  '-cookie-secure=true',
                  '-email-domain=outreach.io',
                  '-http-address=0.0.0.0:9091',
                  '-okta-domain=outreach.okta.com',
                  '-provider=okta',
                  '-redirect-url=https://%s/oauth2/callback' % $.prometheus.ingress.host,
                  '-upstream=http://localhost:10902/',
                ],
                envFrom: [{ secretRef: { name: 'prometheus-proxy' } }],
                image: 'registry.outreach.cloud/oauth2_proxy:2.2.1-alpha.outreach-1.0.7',
                ports_+: { proxy: { containerPort: 9091 } },
              },
            },
            volumes_+:: { data: ok.EmptyDirVolume() },  //HACK
          },
        },
        volumeClaimTemplates: [],
      },
    },
  },

  'thanos-store': $.thanos('store') {
    configmap: ok.ConfigMap('thanos-objstore-config', namespace) {
      data: {
        'objstore-config.yaml': |||
          type: GCS
          config:
            bucket: %s
        ||| % bucket,
      },
    },
    statefulset+: {
      spec+: {
        template+: {
          spec+: {
            containers_+:: {
              default+: {
                args+: [
                  '--block-sync-concurrency=100',
                  '--chunk-pool-size=20GB',
                  '--cluster.peers=thanos-peers.%s.svc.cluster.local:10900' % namespace,
                  '--data-dir=%s' % self.volumeMounts_.data.mountPath,
                  '--index-cache-size=10GB',
                  '--objstore.config-file=/etc/thanos/objstore-config.yaml',
                ],
                livenessProbe+: {
                  failureThreshold: 10,
                  initialDelaySeconds: 60,
                },
              },
            },
          },
        },
      },
    },
  },

  'thanos-rule': $.thanos('rule') {
    configmap: ok.ConfigMap('thanos-rule-loader', namespace) {
      data: {
        'load-rules.sh': |||
          #/usr/bin/env bash
          set -euxo pipefail

          if [[ $# -lt 1 ]]; then
            echo "Usage: load-rules.sh TRIBE"
            exit 1
          fi
          declare -r TRIBE=$1

          function list-rules() {
            kubectl get prometheusrules \
            --all-namespaces \
            --selector=tribe=$TRIBE \
            --output=jsonpath='{ range .items[*].metadata }{ .namespace }.{ .name } { end }'
          }

          function parse-rule() {
            declare ns=${1%.*} name=${1#*.} # <namespace>.<name>
            kubectl get prometheusrule $name -n $ns -o json \
              | python -c 'import json, sys, yaml; yaml.safe_dump(json.load(sys.stdin)["spec"]["groups"], sys.stdout, default_flow_style=False)'
          }

          function validate-rule() {
            # TODO: cache some mapping of invalid rules and their hash,
            # then bypass validation for unchanged, invalid rules that we've already
            # seen, otherwise this is going to get super spammy
            promtool check rules <(echo 'groups:' && parse-rule $1) &>/dev/stderr
          }

          # TODO install promtool
          url='https://github.com/prometheus/prometheus/releases/download/v2.7.1/prometheus-2.7.1.linux-amd64.tar.gz'
          curl -sL $url \
            | tar -xz --strip-components=1 --directory=/usr/local/bin --wildcards "*promtool"

          pip install pyyaml 2>/dev/null

          while :; do
            (
              echo 'groups:'
              for rule in $(list-rules); do
                #FIXME:  we can delete this immediately after it's gone live
                rm -f /etc/prometheus/${rule}.rules.yml
                if validate-rule $rule; then
                  parse-rule $rule
                fi
              done
            ) > /etc/prometheus/${TRIBE}.rules.yml
            curl -X POST localhost:10902/-/reload
            sleep 10
          done
        |||,
      },
    },
    statefulset+: {
      spec+: {
        template+: {
          spec+: {
            containers_+: {
              default+: {
                args+: [
                  '--alert.label-drop=replica',
                  '--alert.query-url=https://%s' % $.prometheus.ingress.host,
                  '--alertmanagers.url=dns+http://alertmanager.%s.svc.cluster.local:9093' % namespace,
                  '--cluster.peers=thanos-peers.%s.svc.cluster.local:10900' % namespace,
                  '--data-dir=/opt/thanos',
                  '--eval-interval=30s',
                  '--label=replica="$(MY_POD_NAME)"',
                  '--objstore.config-file=/etc/thanos/objstore-config.yaml',
                  '--query=thanos-query.monitoring.svc.cluster.local:9090',
                  '--rule-file=/etc/prometheus/*.rules.yml',
                ],
                env_+:: { MY_POD_NAME: ok.FieldRef('metadata.name') },
              },
              reloader: ok.Container('reloader') {
                args: [
                  'sh',
                  '-c',
                  |||
                    while inotifywait -e create -e delete -e modify /etc/prometheus; do
                      curl -s -X POST localhost:10902/-/reload
                    done
                  |||,
                ],
                image: 'pstauffer/inotify:v1.0.1',
                volumeMounts_:: {
                  config: { mountPath: '/etc/prometheus' },
                },
              },
            },
          },
        },
      },
    },
  },

  ruler(tribe):: $.thanos('rule', 'thanos-rule-%s' % tribe) {
    local this = self,

    clusterrole+: ok.ClusterRole(this.name) {
      rules: [{
        apiGroups: ['monitoring.coreos.com'],
        resources: ['prometheusrules'],
        verbs: ['get', 'list', 'watch'],
      }],
    },

    clusterrolebinding: ok.ClusterRoleBinding(this.name) {
      roleRef_: this.clusterrole,
      subjects_: [this.serviceaccount],
    },

    statefulset+: {
      spec+: {
        replicas: 1,
        template+: {
          spec+: {
            containers_+:: {
              default+: {
                args+: [
                  '--alert.label-drop=replica',
                  '--alert.query-url=https://%s' % $.prometheus.ingress.host,
                  '--alertmanagers.url=dns+http//alertmanager.%s.svc.cluster.local:9093' % namespace,
                  '--cluster.peers=thanos-peers.%s.svc.cluster.local:10900' % namespace,
                  '--data-dir=/opt/thanos',
                  '--eval-interval=30s',
                  '--label=replica="$(MY_POD_NAME)"',
                  '--objstore.config-file=/etc/thanos/objstore-config.yaml',
                  '--query=thanos-query.monitoring.svc.cluster.local:9090',
                  '--rule-file=/etc/prometheus/*.rules.yml',
                ],
                env_+:: { MY_POD_NAME: ok.FieldRef('metadata.name') },
              },
              'rule-loader': ok.Container('rule-loader') {
                command: ['bash', '/opt/bin/load-rules.sh', tribe],
                image: 'google/cloud-sdk',
                volumeMounts_:: {
                  bin: { mountPath: '/opt/bin' },
                  config: { mountPath: '/etc/prometheus' },
                },
              },
            },
            volumes_+:: {
              bin: ok.ConfigMapVolume($['thanos-rule'].configmap),
              config: ok.EmptyDirVolume(),
              data: ok.EmptyDirVolume(),
            },
          },
        },
        volumeClaimTemplates: [{
          metadata+: { name: 'data' },
          spec+: {
            accessModes: ['ReadWriteOnce'],
            resources: { requests: { storage: '10Gi' } },
          },
       }],
      },
    },
  },

  'thanos-rule-actions': self.ruler('actions'),
  'thanos-rule-apollo': self.ruler('apollo'),
  'thanos-rule-datascience': self.ruler('datascience'),
  'thanos-rule-dataworkflow': self.ruler('dataworkflow'),
  'thanos-rule-growth': self.ruler('growth'),
  'thanos-rule-otf': self.ruler('otf'),
  'thanos-rule-platform': self.ruler('platform'),
  'thanos-rule-telecom': self.ruler('telecom'),

  items:: std.flattenArrays([ok.objectValues(component) for component in ok.objectValues($)]),
};

ok.List() { items: all().items }

// vim: foldlevel=1
