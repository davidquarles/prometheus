local c = import 'concourse/pipeline.libsonnet';
local slackChannel = '#botland';

// Pipeline is the parent object, it's what makes the magic happen.
local pipeline = c.newPipeline(
  name        = 'prometheus',
  source_repo = 'getoutreach/prometheus',
);


// Standard concourse resources, add custom concourse resources not available in our libs
local resources = [
  pipeline.dockerImage('tools', 'registry.outreach.cloud/alpine/tools', 'latest'),
];


// Master Branch jobs
// local masterGroup       = 'Master';
// local masterBranchJobs  = [
//   // Run Tests
//   pipeline.newJob(
//     name  = 'Run Tests',
//     group = masterGroup,
//   ) {
//     local taskName = 'Test App',
//     plan_: pipeline.steps([
//       // Run `task` as defined in `ci_cd/concourse/tasks/test.yaml`
//       // Trigger when source repo is updated
//       pipeline.newTask(
//         name    = taskName,
//         path    = 'ci_cd/concourse/tasks/test.yaml',
//         trigger = true,
//       ),
//     ]),
//     on_success_: pipeline.do([
//       // Update GitHub state
//       pipeline.updateGithub(
//         name  = taskName,
//         state = 'success',
//       ),
//       // Send slack message
//       pipeline.slackMessage(
//         channel = slackChannel,
//         type    = 'success',
//         title   = ':successkid: Master Branch Passed Tests Successfully!',
//         text    = 'All the tests ran successfully!',
//       ),
//     ]),
//     on_failure_: pipeline.do([
//       // Update GitHub state
//       pipeline.updateGithub(
//         name  = taskName,
//         state = 'failure',
//       ),
//       // Send slack message
//       pipeline.slackMessage(
//         channel = slackChannel,
//         type    = 'failure',
//         title   = ":fire: Master Branch Tests Failed",
//         text    = 'There was a problem running the tests for the master branch.',
//       ),
//     ]),
//   },
//   // Build Image
//   pipeline.newJob(
//     name  = 'Build Image',
//     group = masterGroup,
//   ) {
//     local taskName = 'Build App',
//     plan_: pipeline.steps([
//       // Run `task` as defined in `ci_cd/concourse/tasks/build.yaml`
//       // Trigger when source repo is updated
//       pipeline.newTask(
//         name    = taskName,
//         path    = 'ci_cd/concourse/tasks/build.yaml',
//         image   = 'task_image', // `task_image` is a docker image resource provided by the library
//         passed  = ['Run Tests'], // Don't trigger until this job has successfully completed
//         semver  = { bump: 'patch' }, // Get version and bump patch
//         trigger = true,
//       ),
//       // Build docker image with source `build-output` from the previous task
//       pipeline.buildDockerImage(
//         name      = pipeline.name,
//         source    = 'build-output',
//         latest    = true, // Add additional `latest` tag to image
//         semver    = { bump: 'patch' }, // Get version and bump patch (to match build task)
//         tag_file  = 'build-output/version',
//       ),
//     ]),
//     on_success_: pipeline.do([
//       // Update GitHub state
//       pipeline.updateGithub(
//         name  = taskName,
//         state = 'success',
//       ),
//       // Send slack message
//       pipeline.slackMessage(
//         channel   = slackChannel,
//         type      = 'success',
//         title     = ':successkid: Master Branch Build Succeeded!',
//         text      = 'Build ran successfully!',
//         resources = ['version', pipeline.name], // Resources used in message fields
//         fields    = [
//           pipeline.slackField() {
//             title: 'Image',
//             value: '$(cat %s/repository):$(cat version/version)' % pipeline.name,
//             short: false,
//           },
//         ],
//       ),
//     ]),
//     on_failure_: pipeline.do([
//       // Update GitHub state
//       pipeline.updateGithub(
//         name  = taskName,
//         state = 'failure',
//       ),
//       // Send slack message
//       pipeline.slackMessage(
//         channel   = slackChannel,
//         type      = 'failure',
//         title     = ":fire: Master Branch Build Failed",
//         text      = 'There was a problem building the master branch.',
//         resources = ['version', pipeline.name], // Resources used in message fields
//         fields    = [
//           pipeline.slackField() {
//             title: 'Image',
//             value: '$(cat %s/repository):$(cat version/version)' % pipeline.name,
//             short: false,
//           },
//         ],
//       ),
//     ]),
//   },
//   // Deploy Image
//   pipeline.newJob(
//     name  = 'Deploy Image',
//     group = masterGroup,
//   ) {
//     local taskName      = 'Deploy App',
//     local deployCluster = 'staging.us-west-2',
//     plan_: pipeline.steps([
//       // Trigger when version is updated and `Build Image` has completed successfully
//       pipeline.getSemver(
//         trigger = true,
//         passed  = ['Build Image'],
//       ),
//       // Get Docker Image resource
//       { get: pipeline.name },
//       // Deploy to Kubernetes
//       pipeline.k8sDeploy(
//         debug         = true, // Make resource output debug messages (set to false in production)
//         cluster_name  = deployCluster,
//         namespace     = pipeline.name,
//         vault_secrets = 'deploy/%s/secrets' % pipeline.name,
//         vault_configs = 'deploy/%s/configs/default' % pipeline.name,
//         manifests     = 'ci_cd/k8s/manifests/*.jsonnet',
//         kubecfg_vars  = {
//           env: 'test',
//           fqdn: '%s.outreach.cloud' % pipeline.name,
//           fqdn_int: '%s.intor.io' % pipeline.name,
//           tag: '$(cat version/version)',
//           config_hash: '$(sha256sum secret-default.yaml)',
//           secret_hash: '$(sha256sum configmap-default.yaml)',
//         },
//       ),
//     ]),
//     on_success_: pipeline.do([
//       // Update GitHub state
//       pipeline.updateGithub(
//         name = taskName,
//         state = 'success',
//       ),
//       // Send slack message
//       pipeline.slackMessage(
//         channel   = slackChannel,
//         type      = 'success',
//         title     = ':successkid: Deployment Succeeded!',
//         text      = 'Kubernetes deployment completed successfully!',
//         resources = ['version', pipeline.name], // Resources used in message fields
//         fields    = [
//           pipeline.slackField() {
//             title: 'Image',
//             value: '$(cat %s/repository):$(cat version/version)' % pipeline.name,
//             short: false,
//           },
//           pipeline.slackField() {
//             title: 'Cluster',
//             value: deployCluster,
//             short: true,
//           },
//           pipeline.slackField() {
//             title: 'Namespace',
//             value: pipeline.name,
//             short: true,
//           },
//           pipeline.slackField() {
//             title: 'Tag',
//             value: '$(cat version/version)',
//             short: true,
//           },
//         ],
//       ),
//     ]),
//     on_failure_: pipeline.do([
//       // Update GitHub state
//       pipeline.updateGithub(
//         name  = taskName,
//         state = 'failure',
//       ),
//       // Send slack message
//       pipeline.slackMessage(
//         channel   = slackChannel,
//         type      = 'failure',
//         title     = ":fire: Deployment Failed",
//         text      = 'There was a problem deploying to kubernetes.',
//         resources = ['version', pipeline.name], // Resources used in message fields
//         fields    = [
//           pipeline.slackField() {
//             title: 'Image',
//             value: '$(cat %s/repository):$(cat version/version)' % pipeline.name,
//             short: false,
//           },
//           pipeline.slackField() {
//             title: 'Cluster',
//             value: deployCluster,
//             short: true,
//           },
//           pipeline.slackField() {
//             title: 'Namespace',
//             value: pipeline.name,
//             short: true,
//           },
//           pipeline.slackField() {
//             title: 'Tag',
//             value: '$(cat version/version)',
//             short: true,
//           },
//         ],
//       ),
//     ]),
//   },
// ];


// Pull Request jobs
local prGroup  = '2. Pull Request';
local prJobs   = [
  // Run Tests
  pipeline.newJob(
    name  = 'Run PR Tests',
    group = prGroup,
  ) {
    local taskName = 'Test App',
    plan_: pipeline.steps([
      // Run `task` as defined in `ci_cd/concourse/tasks/test.yaml`
      // Trigger when pull request (source_pr) is updated
      pipeline.newTask(
        name    = taskName,
        image   = 'tools',
        path    = 'ci_cd/concourse/tasks/test.yaml',
        trigger = true,
        pr      = true,
      ),
    ]),
    on_success_: pipeline.do([
      // Update GitHub state
      pipeline.updateGithub(
        name  = taskName,
        state = 'success',
        pr    = true,
      ),
      // Send slack message
      pipeline.slackMessage(
        channel   = slackChannel,
        type      = 'success',
        title     = ':successkid: PR Passed Tests Successfully!',
        text      = 'All the tests ran successfully!',
        resources = ['source_pr'], // Resources used in message fields
        fields    = [
          pipeline.slackField() {
            title: 'Pull Request',
            value: '<$(cat source_pr/.git/url)|#$(cat source_pr/.git/id)>',
            short: true,
          },
        ],
      ),
    ]),
    on_failure_: pipeline.do([
      // Update GitHub state
      pipeline.updateGithub(
        name  = taskName,
        state = 'failure',
        pr    = true,
      ),
      // Send slack message
      pipeline.slackMessage(
        channel   = slackChannel,
        type      = 'failure',
        title     = ":fire: PR Tests Failed",
        text      = 'There was a problem running the tests for this PR.',
        resources = ['source_pr'], // Resources used in message fields
        fields    = [
          pipeline.slackField() {
            title: 'Pull Request',
            value: '<$(cat source_pr/.git/url)|#$(cat source_pr/.git/id)>',
            short: true,
          },
        ],
      ),
    ]),
  },
];

[
  pipeline {
    resources_: resources,
    jobs_: prJobs,
  },
]
