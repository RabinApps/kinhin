// All the words and facts in the title scenes. Edit this file for a new release; the scenes only lay it out.
// Keep claims true to the repo: numbers live in docs/benchmarks.md, supported forges in docs/forges.md.
export const content = {
  intro: {
    title: 'The mindful CI.',
    subtitle: 'kinhin',
  },
  problem: {
    runner: '1 runner',
    queueCaption: 'Your queue waits its turn.',
    limitCaption: 'A self-hosted runner does one job at a time.',
    jobsInQueue: 7,
  },
  lanes: {
    // Supported forges and runtimes only (docs/forges.md, docs/runtimes.md). Not the "planned" ones.
    forges: ['GitHub', 'GitLab', 'Gitea', 'Forgejo'],
    runtimes: ['Tart macOS & Linux VMs', 'apple/container', 'Docker'],
    caption: 'Four forges. Three runtimes. One fleet.',
    note: 'Routed per repo, workflow or runs-on label.',
  },
  outro: {
    line: "One job. One VM. Gone when it's done.",
    url: 'kinhin.dev',
    // Change the last item per release: 'In beta', 'v0.1.0', ...
    facts: ['Free', 'Apache-2.0', 'No telemetry', 'In beta'],
  },
};
