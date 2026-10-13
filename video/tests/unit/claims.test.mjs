import assert from 'node:assert/strict';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {claimsFor, lintProject, textsOf} from '../../scripts/video-claims-lint.mjs';
import {loadProject} from '../../scripts/project.mjs';
import {projectNames} from '../helpers.mjs';

const claims = {planned: ['Buildkite', 'Azure Pipelines', 'Windows'], plannedMarkers: ['planned', 'roadmap'], forbidden: ['fastest', 'enterprise-grade']};
const project = (narration, props = {}) => ({scenes: [{id: 's', type: 'statement', narration, props}]});

test('a planned name is flagged unless the same sentence says it is planned', () => {
  assert.equal(lintProject(project('Works with GitHub and Buildkite.'), claims).length, 1);
  assert.match(lintProject(project('Works with GitHub and Buildkite.'), claims)[0], /"Buildkite" is planned, not shipped/);
  assert.deepEqual(lintProject(project('Buildkite support is planned.'), claims), []);
  assert.deepEqual(lintProject(project('Windows is on the roadmap.'), claims), []);
});

test('names match as words, not as parts of other words', () => {
  assert.deepEqual(lintProject(project('Windowsill gardening.'), claims), []);
  assert.equal(lintProject(project('Runs on Windows 11.'), claims).length, 1);
});

test('tone words are flagged', () => {
  assert.match(lintProject(project('The fastest CI there is.'), claims).join(), /avoid "fastest"/);
  assert.match(lintProject(project('Enterprise-grade security.'), claims).join(), /avoid "enterprise-grade"/);
});

test('every string a viewer sees or hears is checked: cues, say, and nested props, but not file names', () => {
  const p = {scenes: [{id: 'a', type: 'map', props: {left: ['GitHub', 'Buildkite'], clip: 'Buildkite.mp4', caption: 'fine'}, cues: [{text: 'ok', say: 'Azure Pipelines'}]}]};
  const texts = textsOf(p).map((t) => t.text);
  assert.ok(texts.includes('Buildkite') && texts.includes('Azure Pipelines') && texts.includes('fine'));
  assert.ok(!texts.includes('Buildkite.mp4'), 'clip names are not shown');
  assert.equal(lintProject(p, claims).length, 2);
});

test('the kinhin adapter denies the planned platforms and every shipped project passes', () => {
  const k = claimsFor(loadProject('launch'));
  for (const name of ['Buildkite', 'Azure Pipelines', 'Bitbucket', 'Windows']) assert.ok(k.planned.includes(name), name);
  for (const name of projectNames()) {
    const loaded = loadProject(name);
    assert.deepEqual(lintProject(loaded.project, claimsFor(loaded)), [], name);
  }
});

test('a project can add its own rules', () => {
  const loaded = loadProject('examples/hello');
  const merged = claimsFor({...loaded, project: {...loaded.project, claims: {forbidden: ['hello']}}});
  assert.ok(merged.forbidden.includes('hello'));
});

test('the claims of an adapter in your own repository apply to every video that uses it, and a video can add its own', () => {
  const dir = mkdtempSync(join(tmpdir(), 'kinhin-claims-'));
  const videos = join(dir, '.kinhin/videos');
  mkdirSync(join(videos, 'adapters/acme'), {recursive: true});
  writeFileSync(join(videos, 'adapters/acme/adapter.yml'), 'name: acme\nclips: {}\n');
  writeFileSync(join(videos, 'adapters/acme/claims.json'), JSON.stringify({planned: ['Windows'], plannedMarkers: ['planned'], forbidden: ['revolutionary']}));
  const video = (narration, extra = '') => `name: v\nadapter: acme\n${extra}scenes:\n  - id: a\n    type: statement\n    props: {text: hi}\n    narration: ${narration}\n`;
  writeFileSync(join(videos, 'bad.yml'), video('Acme runs on Windows and is revolutionary.'));
  writeFileSync(join(videos, 'good.yml'), video('Windows support is planned.'));
  writeFileSync(join(videos, 'own.yml'), video('Acme is free forever.', 'claims: {forbidden: [forever]}\n'));
  process.env.VIDEO_SOURCE = dir;
  try {
    const problems = (name) => { const l = loadProject(name); return lintProject(l.project, claimsFor(l)); };
    assert.equal(problems('bad').length, 2, 'a planned name stated as shipped, and a forbidden word');
    assert.equal(problems('good').length, 0);
    assert.equal(problems('own').length, 1, 'the video\'s own rules apply too');
  } finally { delete process.env.VIDEO_SOURCE; rmSync(dir, {recursive: true, force: true}); }
});
