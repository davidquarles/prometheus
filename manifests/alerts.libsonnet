local ok = import 'kubernetes/outreach.libsonnet';
local prometheus = import 'kubernetes/prom.libsonnet';
local alertmanager = prometheus.alertmanager;

local default_rules = {

  // downgrade severities outside of ops|production
  local env = ok.cluster.environment,
  critical::
    if std.setMember(env, ['ops', 'production']) then alertmanager.critical
    else if env == 'test' then alertmanager.info
    else alertmanager.warning,
  warning::
    if std.setMember(env, ['ops', 'production']) then alertmanager.warning
    else alertmanager.info,
  info:: alertmanager.info,

  CrashLooping: $.warning('CrashLooping', interval='15m') {
    expr: |||
      sum by (namespace, owner, container)(
        rate(kube_pod_container_status_restarts_total[15m])
        * on (namespace, pod) group_left(owner)
        sum by (namespace, pod, owner)(kube_pod_info_ex)
      ) * 3600 > 0
    |||,
    summary: 'Frequently restarting container(s).',
    description: std.join('\n', [
      '{{- $type      := reReplaceAll "/.*" "" $labels.owner }}',
      '{{- $ns        := $labels.namespace }}',
      '{{- $name      := reReplaceAll ".*/" "" $labels.owner }}',
      '{{- $container := $labels.container }}',
      '{{- printf "%s %s.%s.%s: %.2f" $type $ns $name $container $value }} restarts/hour.',
    ]),
  },

  UnderservedAZ: $.warning('UnderservedAZ') {
    expr: 'sum(up{job="kubernetes_nodes"}) by (failure_domain_beta_kubernetes_io_zone) < 2',
    summary: 'Not enough nodes in AZ',
    description: 'Only {{ $value }} nodes are up in AZ {{ $labels.failure_domain_beta_kubernetes_io_zone }}.',
  },

  // TODO: Explicitly report on conditions (with potentially different thresholds?)
  NodeNotReadyWithConditionInfo: $.info('NodeNotReady', interval='5m') {
    expr: 'kube_node_status_condition{condition!="Ready",status="true"} == 1',
    summary: 'Node(s) not ready for 5 minutes.',
    description: '{{ $labels.node }}: {{ $labels.condition }}.',
  },
  NodeNotReadyWithConditionWarning: $.warning('NodeNotReady', interval='15m') {
    expr: 'kube_node_status_condition{condition!="Ready",status="true"} == 1',
    summary: 'Node(s) not ready for 15 minutes.',
    description: '{{ $labels.node }}: {{ $labels.condition }}.',
  },
  NodeNotReadyWithConditionCritical: $.critical('NodeNotReady', interval='1h') {
    expr: 'kube_node_status_condition{condition!="Ready",status="true"} == 1',
    summary: 'Node(s) not ready for 1 hour.',
    description: '{{ $labels.node }}: {{ $labels.condition }}.',
  },

  NodeNotReadyConditionUnknownInfo: $.info('NodeNotReady', interval='5m') {
    expr: 'kube_node_status_condition{condition="Ready",status="unknown"} == 1',
    summary: 'Node(s) not ready for 5 minutes.',
    description: '{{ $labels.node }} has stopped posting status.',
  },
  NodeNotReadyConditionUnknownWarning: $.warning('NodeNotReady', interval='15m') {
    expr: 'kube_node_status_condition{condition="Ready",status="unknown"} == 1',
    summary: 'Node(s) not ready for 15 minutes.',
    description: '{{ $labels.node }} has stopped posting status.',
  },
  NodeNotReadyConditionUnknownCritical: $.critical('NodeNotReady', interval='1h') {
    expr: 'kube_node_status_condition{condition="Ready",status="unknown"} == 1',
    summary: 'Node(s) not ready for 1 hour.',
    description: '{{ $labels.node }} has stopped posting status.',
  },

  K8sAPIUnavailable: $.critical('K8SAPIUnavailable', interval='10m') {
    expr: 'max(up{job="kubernetes_apiservers"}) != 1',
    summary: 'Kubernetes API is unavailable',
    description: 'Kubernetes API is not responding.',
  },
};

{ groups: [{ name: 'rules', rules: ok.objectValues(default_rules) }] }
