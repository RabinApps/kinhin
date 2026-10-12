import assert from 'node:assert/strict';
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
